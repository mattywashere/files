$erroractionpreference = "stop"
$progresspreference = "silentlycontinue"

$url = "https://raw.githubusercontent.com/mattywashere/files/main/install.ps1"

$command = "irm '$url' | iex"
$encoded = [convert]::tobase64string([text.encoding]::unicode.getbytes($command))

$isadmin = ([security.principal.windowsprincipal][security.principal.windowsidentity]::getcurrent()).isinrole(
    [security.principal.windowsbuiltinrole]::administrator
)

if (!$isadmin) {
    start-process powershell.exe -verb runas -argumentlist "-sta -noprofile -executionpolicy bypass -encodedcommand $encoded"
    exit
}

if ([threading.thread]::currentthread.apartmentstate -ne "STA") {
    start-process powershell.exe -argumentlist "-sta -noprofile -executionpolicy bypass -encodedcommand $encoded"
    exit
}

add-type -assemblyname presentationframework
add-type -assemblyname presentationcore
add-type -assemblyname windowsbase

$curl = (get-command curl.exe -erroraction silentlycontinue).source

if (!$curl) {
    [system.windows.messagebox]::show(
        "curl.exe was not found on this system.",
        "files",
        "ok",
        "error"
    ) | out-null
    exit
}

$root = "c:\matt files"
$office = "c:\office"
$temp = join-path $env:temp "matty-$pid"

[io.directory]::createdirectory($root) | out-null

$script:downloaderrors = @{}
$script:installerrors = @{}
$script:locations = @{}
$script:busy = $false

$names = @{
    1 = "obs"
    2 = "mpv"
    3 = "losslesscut"
    4 = "everything"
    5 = "bulk crap uninstaller"
    6 = "greenshot"
    7 = "notepad++"
    8 = "office"
    9 = "visual c++ redistributables"
    10 = "nvcleanstall"
}

function do-events {
    $frame = new-object windows.threading.dispatcherframe

    $callback = [windows.threading.dispatcheroperationcallback]{
        param($f)
        $f.continue = $false
        return $null
    }

    [windows.threading.dispatcher]::currentdispatcher.begininvoke(
        [windows.threading.dispatcherpriority]::background,
        $callback,
        $frame
    ) | out-null

    [windows.threading.dispatcher]::pushframe($frame)
}

function wait-process-ui($process) {
    while (!$process.hasexited) {
        do-events
        start-sleep -milliseconds 125
        $process.refresh()
    }

    return $process.exitcode
}

function show-status($states, $selected, $message = "") {
    if (!$script:statusbox) {
        return
    }

    $lines = new-object collections.generic.list[string]

    if ($message) {
        $lines.add($message)
        $lines.add("")
    }

    $finished = 0

    foreach ($number in ($selected | sort-object)) {
        $state = $states[$number]

        if (!$state) {
            $state = "queued"
        }

        if ($state -eq "done" -or $state -eq "failed") {
            $finished++
        }

        $lines.add(("{0,-34} {1}" -f $names[$number], $state))
    }

    $script:statusbox.text = $lines -join "`r`n"
    $script:statusbox.scrolltoend()

    if ($selected.count) {
        $script:progress.value = [math]::round(($finished / $selected.count) * 100)
    }
    else {
        $script:progress.value = 0
    }

    do-events
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

    if (test-path -literalpath $target) {
        remove-item -literalpath $target -recurse -force
    }

    [io.directory]::createdirectory($stage) | out-null
    [io.directory]::createdirectory($target) | out-null

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

    $items = @(get-childitem -literalpath $stage -force)

    if (!$items.count) {
        throw "$($package.file) extracted no files"
    }

    $source = $stage

    if ($items.count -eq 1 -and $items[0].psiscontainer) {
        $source = $items[0].fullname
    }

    & robocopy.exe $source $target /e /move /r:1 /w:1 /nfl /ndl /njh /njs /np *> $null
    $code = $lastexitcode

    if ($code -ge 8) {
        throw "robocopy failed with exit code $code"
    }

    if (test-path -literalpath $stage) {
        remove-item -literalpath $stage -recurse -force -erroraction silentlycontinue
    }

    $script:locations[$number] = $target
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

function get-app-location($patterns, $fallbacks) {
    foreach ($path in $fallbacks) {
        if ($path -and (test-path -literalpath $path)) {
            return $path
        }
    }

    $keys = @(
        "hklm:\software\microsoft\windows\currentversion\uninstall\*",
        "hklm:\software\wow6432node\microsoft\windows\currentversion\uninstall\*",
        "hkcu:\software\microsoft\windows\currentversion\uninstall\*"
    )

    foreach ($key in $keys) {
        $apps = get-itemproperty $key -erroraction silentlycontinue

        foreach ($app in $apps) {
            if (!$app.displayname) {
                continue
            }

            foreach ($pattern in $patterns) {
                if ($app.displayname -match $pattern) {
                    if ($app.installlocation -and (test-path -literalpath $app.installlocation)) {
                        return $app.installlocation.trimend("\")
                    }

                    if ($app.displayicon) {
                        $icon = [string]$app.displayicon
                        $icon = $icon.trim('"')
                        $icon = ($icon -split ",")[0]

                        if (test-path -literalpath $icon) {
                            return (split-path -literalpath $icon -parent)
                        }
                    }
                }
            }
        }
    }

    return "installed (location not reported)"
}

function install-winget($name, $id, $number, $states, $selected, $patterns, $fallbacks) {
    if (!(get-command winget.exe -erroraction silentlycontinue)) {
        throw "winget is not installed"
    }

    $states[$number] = "installing"
    show-status $states $selected "installing selected apps..."

    $process = start-process winget.exe -argumentlist @(
        "install", "--id", $id, "--exact", "--source", "winget",
        "--scope", "machine", "--silent",
        "--accept-package-agreements", "--accept-source-agreements",
        "--disable-interactivity"
    ) -passthru -windowstyle hidden

    $code = wait-process-ui $process

    if ($code -ne 0) {
        throw "$name install failed with exit code $code"
    }

    $script:locations[$number] = get-app-location $patterns $fallbacks
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

    $process = start-process $setup -argumentlist "/configure `"$config`"" -passthru -windowstyle hidden
    $code = wait-process-ui $process

    if ($code -ne 0) {
        throw "office install failed with exit code $code"
    }

    $officepaths = @(
        "$env:programfiles\microsoft office\root\office16",
        "${env:programfiles(x86)}\microsoft office\root\office16",
        "$env:programfiles\microsoft office",
        "${env:programfiles(x86)}\microsoft office"
    )

    $officepath = $officepaths | where-object { $_ -and (test-path -literalpath $_) } | select-object -first 1

    if ($officepath) {
        $script:locations[8] = $officepath
    }
    else {
        $script:locations[8] = "installed (location not reported)"
    }

    if (test-path -literalpath $office) {
        remove-item -literalpath $office -recurse -force
    }

    $states[8] = "done"
    show-status $states $selected "installing selected apps..."
}


function install-nvcleanstall($states, $selected) {
    $states[10] = "configuring"
    show-status $states $selected "setting up nvcleanstall..."

    $source = join-path $temp "NVCleanstall_1.19.0.exe"
    $settings = join-path $temp "nvcleanstall-settings.reg"
    $desktop = [environment]::getfolderpath("desktop")
    $target = join-path $desktop "NVCleanstall_1.19.0.exe"

    if (!(test-path -literalpath $source)) {
        throw "nvcleanstall executable was not downloaded"
    }

    if (!(test-path -literalpath $settings)) {
        throw "nvcleanstall settings were not downloaded"
    }

    $reg = start-process reg.exe -argumentlist @(
        "import"
        "`"$settings`""
    ) -passthru -windowstyle hidden

    $regcode = wait-process-ui $reg

    if ($regcode -ne 0) {
        throw "failed to import nvcleanstall settings (exit code $regcode)"
    }

    [io.file]::copy($source, $target, $true)

    $script:locations[10] = $target
    $states[10] = "done"
    show-status $states $selected "installing selected apps..."
}

function install-redists($redists, $states, $selected) {
    $items = @(
        $redists | where-object {
            $_.arch -eq "any" -or [environment]::is64bitoperatingsystem
        }
    )

    $total = $items.count
    $index = 0
    $warnings = @()

    foreach ($item in $items) {
        $index++
        $states[9] = "installing $index/$total"
        show-status $states $selected "installing visual c++ redistributables..."

        $process = start-process $item.path -argumentlist $item.args -passthru -windowstyle hidden
        $code = wait-process-ui $process

        if ($code -notin @(0, 3010, 1641, 1638, -2147023258)) {
            $warnings += "$($item.name) returned exit code $code"
        }
    }

    if ($warnings.count) {
        throw ($warnings -join "; ")
    }

    $script:locations[9] = "system-wide (visual c++ runtime components)"
    $states[9] = "done"
    show-status $states $selected "installing selected apps..."
}



[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="files"
        Width="920"
        Height="700"
        MinWidth="760"
        MinHeight="560"
        WindowStartupLocation="CenterScreen"
        Background="#0f1115"
        Foreground="#f3f4f6"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="#0f1115"/>
            <Setter Property="BorderBrush" Value="#2a2f38"/>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#c9ced6"/>
            <Setter Property="Background" Value="#171a20"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="Margin" Value="0,0,2,0"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#f3f4f6"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="Margin" Value="0,7,0,7"/>
            <Setter Property="Padding" Value="2"/>
        </Style>

        <Style TargetType="Button">
            <Setter Property="Foreground" Value="#f3f4f6"/>
            <Setter Property="Background" Value="#232832"/>
            <Setter Property="BorderBrush" Value="#3a414d"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#2563eb"/>
            <Setter Property="BorderBrush" Value="#3b82f6"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#d9dde4"/>
            <Setter Property="BorderBrush" Value="#2a2f38"/>
            <Setter Property="Margin" Value="0,0,0,16"/>
            <Setter Property="Padding" Value="16"/>
        </Style>
    </Window.Resources>

    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="2,0,2,16">
            <TextBlock Text="files" FontSize="26" FontWeight="SemiBold"/>
            <TextBlock Text="select what you want, then install it in one pass"
                       Foreground="#8d96a5"
                       FontSize="13"
                       Margin="0,4,0,0"/>
        </StackPanel>

        <TabControl Grid.Row="1" x:Name="tabs">
            <TabItem Header="Install">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18">
                    <StackPanel>
                        <GroupBox Header="Portable">
                            <StackPanel>
                                <CheckBox x:Name="chk1" Content="OBS Studio"/>
                                <TextBlock Text="Configured portable OBS, replay buffer, startup + system tray."
                                           Foreground="#8d96a5" Margin="25,-4,0,7"/>
                                <CheckBox x:Name="chk2" Content="MPV"/>
                                <CheckBox x:Name="chk3" Content="LosslessCut"/>
                            </StackPanel>
                        </GroupBox>

                        <GroupBox Header="Applications">
                            <StackPanel>
                                <CheckBox x:Name="chk4" Content="Everything"/>
                                <CheckBox x:Name="chk5" Content="Bulk Crap Uninstaller"/>
                                <CheckBox x:Name="chk6" Content="Greenshot"/>
                                <CheckBox x:Name="chk7" Content="Notepad++"/>
                                <CheckBox x:Name="chk8" Content="Microsoft Office"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="Runtimes">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18">
                    <StackPanel>
                        <GroupBox Header="Redistributables">
                            <StackPanel>
                                <CheckBox x:Name="chk9" Content="Visual C++ Redistributables 2005-2026"/>
                                <TextBlock Text="Installs the x86 and x64 runtime packages silently. x64 packages are skipped on 32-bit Windows."
                                           TextWrapping="Wrap"
                                           Foreground="#8d96a5"
                                           Margin="25,-4,0,7"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="Tools">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18">
                    <StackPanel>
                        <GroupBox Header="Driver Tools">
                            <StackPanel>
                                <CheckBox x:Name="chk10" Content="NVCleanstall 1.19.0"/>
                                <TextBlock Text="Copies NVCleanstall to your Desktop and imports the saved previous-settings preset."
                                           TextWrapping="Wrap"
                                           Foreground="#8d96a5"
                                           Margin="25,-4,0,7"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="About">
                <Grid Padding="18">
                    <StackPanel VerticalAlignment="Top">
                        <TextBlock Text="Matt Files"
                                   FontSize="20"
                                   FontWeight="SemiBold"
                                   Margin="0,0,0,8"/>
                        <TextBlock Text="Windows setup utility for portable apps, common software, runtimes, and tools."
                                   TextWrapping="Wrap"
                                   Foreground="#a6aebb"
                                   Margin="0,0,0,18"/>
                        <Button x:Name="githubButton"
                                Content="Open GitHub"
                                HorizontalAlignment="Left"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>

        <Border Grid.Row="2"
                Background="#15181e"
                BorderBrush="#2a2f38"
                BorderThickness="1"
                CornerRadius="6"
                Padding="12"
                Margin="0,16,0,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <DockPanel Grid.Row="0" LastChildFill="False">
                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                        <Button x:Name="selectAllButton" Content="Select All"/>
                        <Button x:Name="clearButton" Content="Clear"/>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
                        <Button x:Name="closeButton" Content="Close"/>
                        <Button x:Name="installButton"
                                Content="Install Selected"
                                Style="{StaticResource PrimaryButton}"/>
                    </StackPanel>
                </DockPanel>

                <ProgressBar x:Name="progress"
                             Grid.Row="1"
                             Minimum="0"
                             Maximum="100"
                             Height="7"
                             Margin="4,10,4,10"/>

                <TextBox x:Name="statusBox"
                         Grid.Row="2"
                         Height="142"
                         Background="#0c0e12"
                         Foreground="#d7dce4"
                         BorderBrush="#2a2f38"
                         FontFamily="Consolas"
                         FontSize="12"
                         Padding="10"
                         IsReadOnly="True"
                         TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto"
                         HorizontalScrollBarVisibility="Auto"
                         Text="ready. select one or more items, then click install selected."/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = new-object system.xml.xmlnodereader $xaml
$window = [windows.markup.xamlreader]::load($reader)

$script:tabs = $window.findname("tabs")
$script:statusbox = $window.findname("statusBox")
$script:progress = $window.findname("progress")
$script:installbutton = $window.findname("installButton")
$script:selectallbutton = $window.findname("selectAllButton")
$script:clearbutton = $window.findname("clearButton")
$script:closebutton = $window.findname("closeButton")
$script:githubbutton = $window.findname("githubButton")

$script:checkboxes = @{}

1..10 | foreach-object {
    $script:checkboxes[$_] = $window.findname("chk$_")
}

function set-ui-enabled($enabled) {
    1..10 | foreach-object {
        $script:checkboxes[$_].isenabled = $enabled
    }

    $script:selectallbutton.isenabled = $enabled
    $script:clearbutton.isenabled = $enabled
    $script:installbutton.isenabled = $enabled
    $script:tabs.isenabled = $enabled
    $script:closebutton.isenabled = $enabled
}

function set-final-summary($selected, $states, $failed) {
    $lines = new-object collections.generic.list[string]

    if ($failed.count) {
        $lines.add("finished with $($failed.count) failure(s)")
    }
    else {
        $lines.add("finished")
    }

    $lines.add("")

    foreach ($number in ($selected | sort-object)) {
        $state = $states[$number]

        if (!$state) {
            $state = "unknown"
        }

        $lines.add(("{0,-34} {1}" -f $names[$number], $state))
    }

    if ($script:locations.count) {
        $lines.add("")
        $lines.add("installed to")

        foreach ($number in ($selected | sort-object)) {
            if ($script:locations.containskey($number)) {
                $lines.add("  $($names[$number]): $($script:locations[$number])")
            }
        }
    }

    if ($script:downloaderrors.count) {
        $lines.add("")
        $lines.add("download errors")

        foreach ($key in $script:downloaderrors.keys) {
            $lines.add("  $key`: $($script:downloaderrors[$key])")
        }
    }

    if ($script:installerrors.count) {
        $lines.add("")
        $lines.add("install errors")

        foreach ($key in $script:installerrors.keys) {
            $lines.add("  $key`: $($script:installerrors[$key])")
        }
    }

    if (($selected -contains 1) -and ($states[1] -eq "done")) {
        $lines.add("")
        $lines.add("obs note")
        $lines.add("  obs is running in the system tray.")
        $lines.add("  obs will start automatically every time you sign in to windows.")
    }

    if (($selected -contains 10) -and ($states[10] -eq "done")) {
        $lines.add("")
        $lines.add("nvcleanstall note")
        $lines.add("  your saved tweak preset has been imported.")
        $lines.add("  click 'use previous settings' in nvcleanstall to load it.")
    }

    $script:statusbox.text = $lines -join "`r`n"
    $script:statusbox.scrolltoend()
    $script:progress.value = 100
    do-events
}

function invoke-install($selected) {
    $script:downloaderrors = @{}
    $script:installerrors = @{}
    $script:locations = @{}

    $states = @{}
    $failed = @()
    $portables = @()
    $downloads = @()

    foreach ($number in $selected) {
        $states[$number] = "queued"
    }

    if (test-path -literalpath $temp) {
        remove-item -literalpath $temp -recurse -force -erroraction silentlycontinue
    }

    [io.directory]::createdirectory($temp) | out-null

    try {
        show-status $states $selected "preparing..."

        $redists = @()

        if ($selected -contains 10) {
            $states[10] = "downloading"

            $downloads += [pscustomobject]@{
                number = $null
                name = "nvcleanstall-exe"
                url = "https://raw.githubusercontent.com/mattywashere/files/main/nvcleanstall/NVCleanstall_1.19.0.exe"
                path = (join-path $temp "NVCleanstall_1.19.0.exe")
            }

            $downloads += [pscustomobject]@{
                number = $null
                name = "nvcleanstall-settings"
                url = "https://raw.githubusercontent.com/mattywashere/files/main/nvcleanstall/settings.reg"
                path = (join-path $temp "nvcleanstall-settings.reg")
            }
        }

        if ($selected -contains 9) {
            $redisttemp = join-path $temp "redist"
            [io.directory]::createdirectory($redisttemp) | out-null

            $redists = @(
                [pscustomobject]@{ name = "vc++ 2005 x86"; file = "vcredist2005_x86.exe"; args = "/q"; arch = "any" }
                [pscustomobject]@{ name = "vc++ 2005 x64"; file = "vcredist2005_x64.exe"; args = "/q"; arch = "x64" }
                [pscustomobject]@{ name = "vc++ 2008 x86"; file = "vcredist2008_x86.exe"; args = "/q"; arch = "any" }
                [pscustomobject]@{ name = "vc++ 2008 x64"; file = "vcredist2008_x64.exe"; args = "/q"; arch = "x64" }
                [pscustomobject]@{ name = "vc++ 2010 x86"; file = "vcredist2010_x86.exe"; args = "/quiet /norestart"; arch = "any" }
                [pscustomobject]@{ name = "vc++ 2010 x64"; file = "vcredist2010_x64.exe"; args = "/quiet /norestart"; arch = "x64" }
                [pscustomobject]@{ name = "vc++ 2012 x86"; file = "vcredist2012_x86.exe"; args = "/install /quiet /norestart"; arch = "any" }
                [pscustomobject]@{ name = "vc++ 2012 x64"; file = "vcredist2012_x64.exe"; args = "/install /quiet /norestart"; arch = "x64" }
                [pscustomobject]@{ name = "vc++ 2013 x86"; file = "vcredist2013_x86.exe"; args = "/install /quiet /norestart"; arch = "any" }
                [pscustomobject]@{ name = "vc++ 2013 x64"; file = "vcredist2013_x64.exe"; args = "/install /quiet /norestart"; arch = "x64" }
                [pscustomobject]@{ name = "vc++ v14 x86"; file = "vcredist_v14.x86.exe"; args = "/install /quiet /norestart"; arch = "any" }
                [pscustomobject]@{ name = "vc++ v14 x64"; file = "vcredist_v14.x64.exe"; args = "/install /quiet /norestart"; arch = "x64" }
            )

            $states[9] = "downloading"

            foreach ($item in $redists) {
                if ($item.arch -eq "x64" -and -not [environment]::is64bitoperatingsystem) {
                    continue
                }

                $item | add-member -notepropertyname path -notepropertyvalue (join-path $redisttemp $item.file)

                $downloads += [pscustomobject]@{
                    number = $null
                    name = "redist-$($item.file)"
                    url = "https://raw.githubusercontent.com/mattywashere/files/main/redist/$($item.file)"
                    path = $item.path
                }
            }
        }

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

        if ($selected -contains 10) {
            if ($downloadstatus["nvcleanstall-exe"] -and $downloadstatus["nvcleanstall-settings"]) {
                $states[10] = "downloaded"
            }
            else {
                $states[10] = "failed"
                $failed += 10
            }
        }

        if ($selected -contains 9) {
            $redistok = $true

            foreach ($item in $redists) {
                if ($item.arch -eq "x64" -and -not [environment]::is64bitoperatingsystem) {
                    continue
                }

                if (!$downloadstatus["redist-$($item.file)"]) {
                    $redistok = $false
                    break
                }
            }

            if ($redistok) {
                $states[9] = "downloaded"
            }
            else {
                $states[9] = "failed"
                $failed += 9
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

        if (($selected -contains 10) -and ($failed -notcontains 10)) {
            try {
                install-nvcleanstall $states $selected
            }
            catch {
                $states[10] = "failed"
                $script:installerrors["nvcleanstall"] = $_.exception.message
                $failed += 10
                show-status $states $selected "installing selected apps..."
            }
        }

        if (($selected -contains 9) -and ($failed -notcontains 9)) {
            try {
                install-redists $redists $states $selected
            }
            catch {
                $states[9] = "failed"
                $script:installerrors["visual c++ redistributables"] = $_.exception.message
                $failed += 9
                show-status $states $selected "installing selected apps..."
            }
        }

        if ($selected -contains 4) {
            try {
                install-winget "everything" "voidtools.Everything" 4 $states $selected @("^Everything") @("$env:programfiles\Everything", "${env:programfiles(x86)}\Everything")
            }
            catch {
                $states[4] = "failed"
                $script:installerrors["everything"] = $_.exception.message
                $failed += 4
                show-status $states $selected "installing selected apps..."
            }
        }

        if ($selected -contains 5) {
            try {
                install-winget "bulk crap uninstaller" "Klocman.BulkCrapUninstaller" 5 $states $selected @("Bulk Crap Uninstaller", "BCUninstaller") @("$env:programfiles\BCUninstaller", "${env:programfiles(x86)}\BCUninstaller")
            }
            catch {
                $states[5] = "failed"
                $script:installerrors["bulk crap uninstaller"] = $_.exception.message
                $failed += 5
                show-status $states $selected "installing selected apps..."
            }
        }

        if ($selected -contains 6) {
            try {
                install-winget "greenshot" "Greenshot.Greenshot" 6 $states $selected @("^Greenshot") @("$env:programfiles\Greenshot", "${env:programfiles(x86)}\Greenshot")
            }
            catch {
                $states[6] = "failed"
                $script:installerrors["greenshot"] = $_.exception.message
                $failed += 6
                show-status $states $selected "installing selected apps..."
            }
        }

        if ($selected -contains 7) {
            try {
                install-winget "notepad++" "Notepad++.Notepad++" 7 $states $selected @("Notepad\+\+") @("$env:programfiles\Notepad++", "${env:programfiles(x86)}\Notepad++")
            }
            catch {
                $states[7] = "failed"
                $script:installerrors["notepad++"] = $_.exception.message
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
                $script:installerrors["office"] = $_.exception.message
                $failed += 8
                show-status $states $selected "installing selected apps..."
            }
        }
    }
    finally {
        if (test-path -literalpath $temp) {
            remove-item -literalpath $temp -recurse -force -erroraction silentlycontinue
        }
    }

    $failed = @($failed | sort-object -unique)
    set-final-summary $selected $states $failed
}

$script:selectallbutton.add_click({
    1..10 | foreach-object {
        $script:checkboxes[$_].ischecked = $true
    }
})

$script:clearbutton.add_click({
    1..10 | foreach-object {
        $script:checkboxes[$_].ischecked = $false
    }
})

$script:githubbutton.add_click({
    start-process "https://github.com/mattywashere/files"
})

$script:closebutton.add_click({
    if (!$script:busy) {
        $window.close()
    }
})

$window.add_closing({
    param($sender, $eventargs)

    if ($script:busy) {
        $eventargs.cancel = $true
    }
})

$script:installbutton.add_click({
    $selected = @(
        1..10 | where-object {
            $script:checkboxes[$_].ischecked -eq $true
        }
    )

    if (!$selected.count) {
        [system.windows.messagebox]::show(
            "Select at least one item first.",
            "files",
            "ok",
            "information"
        ) | out-null

        return
    }

    $script:busy = $true
    set-ui-enabled $false
    $script:statusbox.text = "starting..."
    $script:progress.value = 0
    do-events

    try {
        invoke-install $selected
    }
    catch {
        $script:statusbox.text = "installer error:`r`n`r`n$($_.exception.message)"
        $script:statusbox.scrolltoend()
    }
    finally {
        $script:busy = $false
        set-ui-enabled $true
        do-events
    }
})

$window.showdialog() | out-null
