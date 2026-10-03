$erroractionpreference = "stop"
$url = "https://raw.githubusercontent.com/mattywashere/files/main/install.ps1"

if (-not ([security.principal.windowsprincipal][security.principal.windowsidentity]::getcurrent()).isinrole([security.principal.windowsbuiltinrole]::administrator)) {
    $command = "irm '$url' | iex"
    $encoded = [convert]::tobase64string([text.encoding]::unicode.getbytes($command))

    start-process powershell.exe -verb runas -argumentlist "-noprofile -executionpolicy bypass -encodedcommand $encoded"
    exit
}

$root = "c:\[-]"
$office = "c:\office"
$temp = join-path $env:temp "matty-$pid"
$releaseurl = "https://api.github.com/repos/mattywashere/files/releases/latest"

function get-release {
    if (!$script:release) {
        $script:release = invoke-restmethod $releaseurl -headers @{"user-agent"="powershell"}
    }

    $script:release
}

function get-portable($name, $pattern) {
    $release = get-release
    $asset = $release.assets | where-object { $_.name -match $pattern } | select-object -first 1

    if (!$asset) {
        throw "release asset not found for $name"
    }

    [pscustomobject]@{
        name = $name
        file = $asset.name
        url = $asset.browser_download_url
        path = (join-path $temp $asset.name)
    }
}

function download-parallel($downloads) {
    $status = @{}

    if (!$downloads.count) {
        return $status
    }

    write-host ""
    write-host "[+] downloading $($downloads.count) file(s) in parallel"

    $jobs = @()

    foreach ($download in $downloads) {
        $jobs += start-job -name $download.name -argumentlist $download.url, $download.path -scriptblock {
            param($url, $path)

            $erroractionpreference = "stop"
            [net.servicepointmanager]::securityprotocol = [net.securityprotocoltype]::tls12

            try {
                invoke-webrequest $url -outfile $path -usebasicparsing

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

    $jobs | wait-job | out-null

    foreach ($job in $jobs) {
        $result = @(receive-job $job) | select-object -last 1

        if ($result -and $result.ok) {
            $status[$job.name] = $true
            write-host "[+] downloaded $($job.name)"
        }
        else {
            $status[$job.name] = $false

            if ($result.error) {
                write-host "[-] $($job.name): $($result.error)"
            }
            else {
                write-host "[-] $($job.name): download failed"
            }
        }
    }

    $jobs | remove-job -force
    return $status
}

function install-portable($package) {
    $name = $package.name
    $archive = $package.path
    $stage = join-path $temp "$name-stage"
    $target = join-path $root $name

    if (test-path -literalpath $stage) {
        remove-item -literalpath $stage -recurse -force
    }

    [io.directory]::createdirectory($stage) | out-null

    write-host "[+] extracting $name"

    if ($package.file -match "\.zip$") {
        expand-archive -literalpath $archive -destinationpath $stage -force
    }
    elseif ($package.file -match "\.7z$") {
        & tar.exe -xf $archive -c $stage

        if ($lastexitcode) {
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

    if ($items.count -eq 1 -and $items[0].psiscontainer) {
        move-item -literalpath $items[0].fullname -destination $target
    }
    else {
        [io.directory]::createdirectory($target) | out-null
        $items | move-item -destination $target -force
    }

    write-host "[+] installed $name -> $target"
}

function set-obs-startup {
    $obs = get-childitem -literalpath "$root\obs" -filter obs64.exe -file -recurse | select-object -first 1

    if (!$obs) {
        throw "obs64.exe not found"
    }

    $startup = [environment]::getfolderpath("startup")
    $shell = new-object -comobject wscript.shell
    $shortcut = $shell.createshortcut((join-path $startup "obs.lnk"))

    $shortcut.targetpath = $obs.fullname
    $shortcut.arguments = "--startreplaybuffer --minimize-to-tray --disable-shutdown-check"
    $shortcut.workingdirectory = $obs.directoryname
    $shortcut.iconlocation = "$($obs.fullname),0"
    $shortcut.save()

    write-host "[+] obs startup shortcut created"
}

function install-winget($name, $id) {
    if (!(get-command winget.exe -erroraction silentlycontinue)) {
        throw "winget is not installed"
    }

    write-host "[+] installing $name"

    & winget.exe install --id $id --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity

    if ($lastexitcode) {
        throw "$name install failed"
    }

    write-host "[+] installed $name"
}

function install-office {
    [io.directory]::createdirectory($office) | out-null

    $setup = join-path $office "setup.exe"
    $config = join-path $office "Configuration.xml"

    copy-item -literalpath (join-path $temp "office-setup.exe") -destination $setup -force
    copy-item -literalpath (join-path $temp "office-configuration.xml") -destination $config -force

    write-host "[+] installing office"

    $process = start-process $setup -argumentlist "/configure `"$config`"" -wait -passthru

    if ($process.exitcode) {
        throw "office install failed with exit code $($process.exitcode)"
    }

    write-host "[+] installed office"
}

clear-host

write-host ""
write-host "select what to install"
write-host ""
write-host "[1] obs"
write-host "[2] mpv"
write-host "[3] losslesscut"
write-host "[4] everything"
write-host "[5] bulk crap uninstaller"
write-host "[6] greenshot"
write-host "[7] notepad++"
write-host "[8] office"
write-host ""
write-host "[a] all"
write-host "[q] quit"
write-host ""

$choice = (read-host "selection (example: 1,2,4,8)").trim().tolower()

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
    write-host "[-] nothing selected"
    read-host "press enter to exit"
    exit
}

$failed = @()
$portables = @()
$downloads = @()

[io.directory]::createdirectory($temp) | out-null

try {
    if ($selected -contains 1) {
        try {
            $package = get-portable "obs" "(?i)^obs.*\.(zip|7z)$"
            $portables += $package
            $downloads += [pscustomobject]@{
                name = "obs"
                url = $package.url
                path = $package.path
            }
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 1
        }
    }

    if ($selected -contains 2) {
        try {
            $package = get-portable "mpv" "(?i)^mpv.*\.(zip|7z)$"
            $portables += $package
            $downloads += [pscustomobject]@{
                name = "mpv"
                url = $package.url
                path = $package.path
            }
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 2
        }
    }

    if ($selected -contains 3) {
        try {
            $package = get-portable "losslesscut" "(?i)^lossless[.\s_-]*cut.*\.(zip|7z)$"
            $portables += $package
            $downloads += [pscustomobject]@{
                name = "losslesscut"
                url = $package.url
                path = $package.path
            }
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 3
        }
    }

    if ($selected -contains 8) {
        $downloads += [pscustomobject]@{
            name = "office-setup"
            url = "https://raw.githubusercontent.com/mattywashere/files/main/office/setup.exe"
            path = (join-path $temp "office-setup.exe")
        }

        $downloads += [pscustomobject]@{
            name = "office-config"
            url = "https://raw.githubusercontent.com/mattywashere/files/main/office/Configuration.xml"
            path = (join-path $temp "office-configuration.xml")
        }
    }

    $downloadstatus = download-parallel $downloads

    foreach ($package in $portables) {
        $number = switch ($package.name) {
            "obs" { 1 }
            "mpv" { 2 }
            "losslesscut" { 3 }
        }

        if (!$downloadstatus[$package.name]) {
            if ($failed -notcontains $number) {
                $failed += $number
            }

            continue
        }

        try {
            install-portable $package

            if ($package.name -eq "obs") {
                set-obs-startup
            }
        }
        catch {
            write-host "[-] $($_.exception.message)"

            if ($failed -notcontains $number) {
                $failed += $number
            }
        }
    }

    if ($selected -contains 4) {
        try {
            install-winget "everything" "voidtools.Everything"
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 4
        }
    }

    if ($selected -contains 5) {
        try {
            install-winget "bulk crap uninstaller" "Klocman.BulkCrapUninstaller"
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 5
        }
    }

    if ($selected -contains 6) {
        try {
            install-winget "greenshot" "Greenshot.Greenshot"
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 6
        }
    }

    if ($selected -contains 7) {
        try {
            install-winget "notepad++" "Notepad++.Notepad++"
        }
        catch {
            write-host "[-] $($_.exception.message)"
            $failed += 7
        }
    }

    if ($selected -contains 8) {
        if (!$downloadstatus["office-setup"] -or !$downloadstatus["office-config"]) {
            $failed += 8
            write-host "[-] office files failed to download"
        }
        else {
            try {
                install-office
            }
            catch {
                write-host "[-] $($_.exception.message)"
                $failed += 8
            }
        }
    }
}
finally {
    if (get-job -erroraction silentlycontinue) {
        get-job | remove-job -force -erroraction silentlycontinue
    }

    if (test-path -literalpath $temp) {
        remove-item -literalpath $temp -recurse -force
    }
}

$failed = @($failed | sort-object -unique)

write-host ""

if ($failed.count) {
    write-host "[-] finished with $($failed.count) failure(s)"
}
else {
    write-host "[+] finished"
}

read-host "press enter to exit"
