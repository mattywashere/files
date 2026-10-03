$erroractionpreference = "stop"
$progresspreference = "silentlycontinue"

$url = "https://raw.githubusercontent.com/mattywashere/files/main/install.ps1"

try {
    $host.ui.rawui.windowtitle = "files"
} catch {}

if (-not ([security.principal.windowsprincipal][security.principal.windowsidentity]::getcurrent()).isinrole([security.principal.windowsbuiltinrole]::administrator)) {
    $command = "irm '$url' | iex"
    $encoded = [convert]::tobase64string([text.encoding]::unicode.getbytes($command))
    start-process powershell.exe -verb runas -argumentlist "-noprofile -executionpolicy bypass -encodedcommand $encoded"
    exit
}

$curl = (get-command curl.exe -erroraction silentlycontinue).source

if (!$curl) {
    throw "curl.exe not found"
}

$root = "c:\matt files"
$office = "c:\office"
$temp = join-path $env:temp "matty-$pid"

[io.directory]::createdirectory($root) | out-null

$downloaderrors = @{}
$installerrors = @{}

$names = @{
    1 = "obs"
    2 = "mpv"
    3 = "losslesscut"
    4 = "everything"
    5 = "bulk crap uninstaller"
    6 = "greenshot"
    7 = "notepad++"
    8 = "office"
}

function get-width {
    try {
        $width = [console]::windowwidth - 1
    }
    catch {
        $width = 72
    }

    if ($width -lt 42) { $width = 42 }
    if ($width -gt 78) { $width = 78 }

    return $width
}

function write-rule {
    write-host ("-" * (get-width))
}

function show-menu {
    clear-host

    write-host "files"
    write-rule
    write-host ""
    write-host "portable"
    write-host "  [1] obs"
    write-host "  [2] mpv"
    write-host "  [3] losslesscut"
    write-host ""
    write-host "installed apps"
    write-host "  [4] everything"
    write-host "  [5] bulk crap uninstaller"
    write-host "  [6] greenshot"
    write-host "  [7] notepad++"
    write-host "  [8] office"
    write-host ""
    write-rule
    write-host "[a] all    [q] quit"
    write-host ""
}

function show-status($states, $selected, $message = "") {
    clear-host

    write-host "files"
    write-rule

    if ($message) {
        write-host ""
        write-host $message
    }

    write-host ""

    foreach ($number in $selected) {
        $name = $names[$number]
        $state = $states[$number]

        if (!$state) {
            $state = "queued"
        }

        $width = get-width
        $statewidth = 14
        $namewidth = $width - $statewidth - 1

        if ($name.length -gt $namewidth) {
            $name = $name.substring(0, [math]::max(1, $namewidth - 3)) + "..."
        }

        write-host ("{0,-$namewidth} {1,$statewidth}" -f $name, $state)
    }

    write-host ""
    write-rule
}

function download-parallel($downloads, $states, $selected) {
    $status = @{}

    if (!$downloads.count) {
        return $status
    }

    $jobs = @()
    $handled = @{}

    try {
        foreach ($download in $downloads) {
            if ($download.number) {
                $states[$download.number] = "downloading"
            }

            $jobs += start-job -name $download.name -argumentlist $download.url, $download.path, $curl -scriptblock {
                param($url, $path, $curl)

                $erroractionpreference = "stop"
                $progresspreference = "silentlycontinue"
                [net.servicepointmanager]::securityprotocol = [net.securityprotocoltype]::tls12

                try {
                    $curlerror = ""

                    try {
                        $output = & $curl -L -f -sS --retry 3 --retry-delay 1 -o $path $url 2>&1

                        if ($lastexitcode -ne 0) {
                            $curlerror = ($output | out-string).trim()
                            throw "curl failed with exit code $lastexitcode"
                        }

                        if (!(test-path -literalpath $path) -or (get-item -literalpath $path).length -le 0) {
                            throw "curl produced an empty file"
                        }
                    }
                    catch {
                        remove-item -literalpath $path -force -erroraction silentlycontinue

                        try {
                            invoke-webrequest $url -outfile $path -usebasicparsing

                            if (!(test-path -literalpath $path) -or (get-item -literalpath $path).length -le 0) {
                                throw "fallback produced an empty file"
                            }
                        }
                        catch {
                            $fallback = $_.exception.message

                            if ($curlerror) {
                                throw "curl: $curlerror | fallback: $fallback"
                            }

                            throw "curl failed; fallback: $fallback"
                        }
                    }

                    [pscustomobject]@{
                        ok = $true
                        error = ""
                    }
                }
                catch {
                    [pscustomobject]@{
                        ok = $false
                        error = $_.exception.message
                    }
                }
            }
        }

        while (($jobs | where-object state -in @("notstarted", "running")).count) {
            show-status $states $selected "downloading selected files..."
            start-sleep -milliseconds 300

            foreach ($job in $jobs | where-object state -eq "completed") {
                if ($handled[$job.id]) {
                    continue
                }

                $download = $downloads | where-object name -eq $job.name | select-object -first 1
                $result = @(receive-job $job) | select-object -last 1
                $handled[$job.id] = $true

                if ($result -and $result.ok) {
                    $status[$job.name] = $true

                    if ($download.number) {
                        $states[$download.number] = "downloaded"
                    }
                }
                else {
                    $status[$job.name] = $false

                    if ($result -and $result.error) {
                        $script:downloaderrors[$job.name] = $result.error
                    }

                    if ($download.number) {
                        $states[$download.number] = "failed"
                    }
                }
            }
        }

        foreach ($job in $jobs) {
            if ($handled[$job.id]) {
                continue
            }

            $download = $downloads | where-object name -eq $job.name | select-object -first 1
            $result = @(receive-job $job) | select-object -last 1
            $handled[$job.id] = $true

            if ($result -and $result.ok) {
                $status[$job.name] = $true

                if ($download.number) {
                    $states[$download.number] = "downloaded"
                }
            }
            else {
                $status[$job.name] = $false

                if ($result -and $result.error) {
                    $script:downloaderrors[$job.name] = $result.error
                }

                if ($download.number) {
                    $states[$download.number] = "failed"
                }
            }
        }

        show-status $states $selected "downloads complete"
        return $status
    }
    finally {
        if ($jobs.count) {
            $jobs | remove-job -force -erroraction silentlycontinue
        }
    }
}

function install-portable($package, $number, $states, $selected) {
    $name = $package.name
    $archive = $package.path
    $stage = join-path $temp "$name-stage"
    $target = join-path $root $name

    [io.directory]::createdirectory($root) | out-null

    $states[$number] = "extracting"
    show-status $states $selected "installing selected apps..."

    if (test-path -literalpath $stage) {
        remove-item -literalpath $stage -recurse -force
    }

    [io.directory]::createdirectory($stage) | out-null

    if ($package.file -match "\.zip$") {
        & tar.exe -xf $archive -C $stage *> $null

        if ($lastexitcode -ne 0) {
            remove-item -literalpath $stage -recurse -force -erroraction silentlycontinue
            [io.directory]::createdirectory($stage) | out-null
            expand-archive -literalpath $archive -destinationpath $stage -force
        }
    }
    elseif ($package.file -match "\.7z$") {
        & tar.exe -xf $archive -C $stage *> $null

        if ($lastexitcode -ne 0) {
            throw "failed to extract $($package.file)"
        }
    }
    else {
        throw "unsupported archive: $($package.file)"
    }

    if (test-path -literalpath $target) {
        remove-item -literalpath $target -recurse -force
    }

    $items = @(get-childitem -literalpath $stage -force)

    if (!$items.count) {
        throw "$($package.file) extracted no files"
    }

    if ($items.count -eq 1 -and $items[0].psiscontainer) {
        [io.directory]::move($items[0].fullname, $target)
    }
    else {
        [io.directory]::createdirectory($target) | out-null

        foreach ($item in $items) {
            $destination = [io.path]::combine($target, $item.name)

            if ($item.psiscontainer) {
                [io.directory]::move($item.fullname, $destination)
            }
            else {
                [io.file]::move($item.fullname, $destination)
            }
        }
    }

    $states[$number] = "done"
    show-status $states $selected "installing selected apps..."
}

function set-obs-startup {
    $obs = get-childitem -literalpath "$root\obs" -filter obs64.exe -file -recurse | select-object -first 1

    if (!$obs) {
        throw "obs64.exe not found"
    }

    $startup = [environment]::getfolderpath("startup")
    $link = join-path $startup "obs.lnk"
    $shell = new-object -comobject wscript.shell
    $shortcut = $shell.createshortcut($link)

    $shortcut.targetpath = $obs.fullname
    $shortcut.arguments = "--startreplaybuffer --minimize-to-tray --disable-shutdown-check"
    $shortcut.workingdirectory = $obs.directoryname
    $shortcut.iconlocation = "$($obs.fullname),0"
    $shortcut.save()

    if (!(get-process obs64 -erroraction silentlycontinue)) {
        start-process $link
    }
}

function install-winget($name, $id, $number, $states, $selected) {
    if (!(get-command winget.exe -erroraction silentlycontinue)) {
        throw "winget is not installed"
    }

    $states[$number] = "installing"
    show-status $states $selected "installing selected apps..."

    & winget.exe install --id $id --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity *> $null

    if ($lastexitcode) {
        throw "$name install failed"
    }

    $states[$number] = "done"
    show-status $states $selected "installing selected apps..."
}

function install-office($states, $selected) {
    [io.directory]::createdirectory($office) | out-null

    $setup = join-path $office "setup.exe"
    $config = join-path $office "Configuration.xml"

    copy-item -literalpath (join-path $temp "office-setup.exe") -destination $setup -force
    copy-item -literalpath (join-path $temp "office-configuration.xml") -destination $config -force

    $states[8] = "installing"
    show-status $states $selected "installing office..."

    $process = start-process $setup -argumentlist "/configure `"$config`"" -wait -passthru -windowstyle hidden

    if ($process.exitcode) {
        throw "office install failed with exit code $($process.exitcode)"
    }

    $states[8] = "done"
    show-status $states $selected "installing selected apps..."
}

show-menu
$choice = (read-host "selection").trim().tolower()

if ($choice -eq "q") {
    exit
}

if ($choice -eq "a") {
    $selected = 1..8
}
else {
    $selected = @(
        $choice -split "," |
        foreach-object { $_.trim() } |
        where-object { $_ -match "^[1-8]$" } |
        foreach-object { [int]$_ } |
        sort-object -unique
    )
}

if (!$selected.count) {
    clear-host
    write-host "nothing selected"
    start-sleep 1
    exit
}

$states = @{}
$failed = @()
$portables = @()
$downloads = @()

foreach ($number in $selected) {
    $states[$number] = "queued"
}

[io.directory]::createdirectory($temp) | out-null

try {
    show-status $states $selected "preparing..."

    if ($selected -contains 1) {
        $package = [pscustomobject]@{
            name = "obs"
            file = "obs.zip"
            url = "https://github.com/mattywashere/files/releases/latest/download/obs.zip"
            path = (join-path $temp "obs.zip")
        }

        $portables += [pscustomobject]@{ number = 1; package = $package }
        $downloads += [pscustomobject]@{ number = 1; name = "obs"; url = $package.url; path = $package.path }
    }

    if ($selected -contains 2) {
        $package = [pscustomobject]@{
            name = "mpv"
            file = "mpv.zip"
            url = "https://github.com/mattywashere/files/releases/latest/download/mpv.zip"
            path = (join-path $temp "mpv.zip")
        }

        $portables += [pscustomobject]@{ number = 2; package = $package }
        $downloads += [pscustomobject]@{ number = 2; name = "mpv"; url = $package.url; path = $package.path }
    }

    if ($selected -contains 3) {
        $package = [pscustomobject]@{
            name = "losslesscut"
            file = "losslesscut.zip"
            url = "https://github.com/mattywashere/files/releases/latest/download/losslesscut.zip"
            path = (join-path $temp "losslesscut.zip")
        }

        $portables += [pscustomobject]@{ number = 3; package = $package }
        $downloads += [pscustomobject]@{ number = 3; name = "losslesscut"; url = $package.url; path = $package.path }
    }

    if ($selected -contains 8) {
        $states[8] = "downloading"

        $downloads += [pscustomobject]@{
            number = $null
            name = "office-setup"
            url = "https://raw.githubusercontent.com/mattywashere/files/main/office/setup.exe"
            path = (join-path $temp "office-setup.exe")
        }

        $downloads += [pscustomobject]@{
            number = $null
            name = "office-config"
            url = "https://raw.githubusercontent.com/mattywashere/files/main/office/Configuration.xml"
            path = (join-path $temp "office-configuration.xml")
        }
    }

    $downloadstatus = download-parallel $downloads $states $selected

    if ($selected -contains 8) {
        if ($downloadstatus["office-setup"] -and $downloadstatus["office-config"]) {
            $states[8] = "downloaded"
        }
        else {
            $states[8] = "failed"
            $failed += 8
        }
    }

    foreach ($entry in $portables) {
        $number = $entry.number
        $package = $entry.package

        if (!$downloadstatus[$package.name]) {
            $states[$number] = "failed"

            if ($failed -notcontains $number) {
                $failed += $number
            }

            continue
        }

        try {
            install-portable $package $number $states $selected

            if ($number -eq 1) {
                set-obs-startup
            }
        }
        catch {
            $states[$number] = "failed"
            $script:installerrors[$package.name] = $_.exception.message

            if ($failed -notcontains $number) {
                $failed += $number
            }

            show-status $states $selected "installing selected apps..."
        }
    }

    if ($selected -contains 4) {
        try {
            install-winget "everything" "voidtools.Everything" 4 $states $selected
        }
        catch {
            $states[4] = "failed"
            $failed += 4
            show-status $states $selected "installing selected apps..."
        }
    }

    if ($selected -contains 5) {
        try {
            install-winget "bulk crap uninstaller" "Klocman.BulkCrapUninstaller" 5 $states $selected
        }
        catch {
            $states[5] = "failed"
            $failed += 5
            show-status $states $selected "installing selected apps..."
        }
    }

    if ($selected -contains 6) {
        try {
            install-winget "greenshot" "Greenshot.Greenshot" 6 $states $selected
        }
        catch {
            $states[6] = "failed"
            $failed += 6
            show-status $states $selected "installing selected apps..."
        }
    }

    if ($selected -contains 7) {
        try {
            install-winget "notepad++" "Notepad++.Notepad++" 7 $states $selected
        }
        catch {
            $states[7] = "failed"
            $failed += 7
            show-status $states $selected "installing selected apps..."
        }
    }

    if (($selected -contains 8) -and ($failed -notcontains 8)) {
        try {
            install-office $states $selected
        }
        catch {
            $states[8] = "failed"
            $failed += 8
            show-status $states $selected "installing selected apps..."
        }
    }
}
finally {
    if (test-path -literalpath $temp) {
        remove-item -literalpath $temp -recurse -force
    }
}

$failed = @($failed | sort-object -unique)

if ($failed.count) {
    show-status $states $selected "finished with $($failed.count) failure(s)"

    if ($downloaderrors.count) {
        write-host ""
        write-host "download errors"

        foreach ($key in $downloaderrors.keys) {
            $message = [string]$downloaderrors[$key]

            if ($message.length -gt 180) {
                $message = $message.substring(0, 177) + "..."
            }

            write-host "  $key`: $message"
        }
    }

    if ($installerrors.count) {
        write-host ""
        write-host "install errors"

        foreach ($key in $installerrors.keys) {
            $message = [string]$installerrors[$key]

            if ($message.length -gt 180) {
                $message = $message.substring(0, 177) + "..."
            }

            write-host "  $key`: $message"
        }
    }
}
else {
    show-status $states $selected "finished"
}

write-host ""
read-host "press enter to exit"
