$erroractionpreference = "stop"
$progresspreference = "silentlycontinue"

$url = "https://raw.githubusercontent.com/mattywashere/files/main/install.ps1?cache=$([guid]::newguid().tostring())"
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

    if (!$script:progress.isindeterminate) {
        if ($selected.count) {
            $script:progress.value = [math]::round(($finished / $selected.count) * 100)
        }
        else {
            $script:progress.value = 0
        }
    }

    do-events
}


function set-download-speed($mbps, $bytes = 0, $active = $false) {
    if (!$script:speedtext) {
        return
    }

    if ($active) {
        $received = $bytes / 1000000
        $script:speedtext.text = ("download speed: {0:N2} mb/s   |   {1:N1} mb received" -f $mbps, $received)
        $script:progress.isindeterminate = $true
    }
    else {
        $script:speedtext.text = "download speed: -- mb/s"
        $script:progress.isindeterminate = $false
    }

    do-events
}

function get-download-bytes($downloads) {
    [int64]$bytes = 0

    foreach ($download in $downloads) {
        if (test-path -literalpath $download.path) {
            try {
                $bytes += (get-item -literalpath $download.path -erroraction stop).length
            }
            catch {}
        }
    }

    return $bytes
}


function download-parallel($downloads, $states, $selected) {
    $status = @{}

    if (!$downloads.count) {
        return $status
    }

    $jobs = @()
    $handled = @{}

    [int64]$lastbytes = 0
    $lastsample = [datetime]::utcnow
    [double]$smoothedspeed = 0

    set-download-speed 0 0 $true

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

            $now = [datetime]::utcnow
            $bytes = get-download-bytes $downloads
            $seconds = ($now - $lastsample).totalSeconds

            if ($seconds -gt 0) {
                $delta = [math]::max(0, ($bytes - $lastbytes))
                $instant = ($delta / $seconds) / 1000000

                if ($smoothedspeed -le 0) {
                    $smoothedspeed = $instant
                }
                else {
                    $smoothedspeed = ($smoothedspeed * 0.65) + ($instant * 0.35)
                }

                set-download-speed $smoothedspeed $bytes $true
                $lastbytes = $bytes
                $lastsample = $now
            }

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
        set-download-speed 0 0 $false
        return $status
    }
    finally {
        set-download-speed 0 0 $false

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
        Width="1040"
        Height="720"
        MinWidth="900"
        MinHeight="620"
        WindowStartupLocation="CenterScreen"
        Background="#000000"
        Foreground="#fafafa"
        FontFamily="Segoe UI">

    <Window.Resources>
        <SolidColorBrush x:Key="Bg" Color="#000000"/>
        <SolidColorBrush x:Key="Surface" Color="#1a1a1a"/>
        <SolidColorBrush x:Key="Surface2" Color="#292929"/>
        <SolidColorBrush x:Key="Border" Color="#434343"/>
        <SolidColorBrush x:Key="Text" Color="#fafafa"/>
        <SolidColorBrush x:Key="Muted" Color="#a5a5a5"/>
        <SolidColorBrush x:Key="Accent" Color="#767676"/>
        <SolidColorBrush x:Key="AccentDark" Color="#575757"/>

        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Surface2}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="buttonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              Margin="14,10"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="buttonBorder" Property="BorderBrush" Value="#767676"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="buttonBorder" Property="Background" Value="#434343"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="buttonBorder" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#fafafa"/>
            <Setter Property="Foreground" Value="#000000"/>
            <Setter Property="BorderBrush" Value="#fafafa"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style x:Key="NavButton" TargetType="Button">
            <Setter Property="Foreground" Value="#a5a5a5"/>
            <Setter Property="Background" Value="#000000"/>
            <Setter Property="BorderBrush" Value="#000000"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Height" Value="48"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="navBg"
                                    Background="{TemplateBinding Background}"
                                    CornerRadius="8"/>
                            <Border x:Name="navAccent"
                                    Width="3"
                                    HorizontalAlignment="Left"
                                    Margin="2,10,0,10"
                                    Background="Transparent"
                                    CornerRadius="2"/>
                            <ContentPresenter Margin="18,0,10,0"
                                              HorizontalAlignment="Left"
                                              VerticalAlignment="Center"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CardCheck" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="card"
                                Background="{StaticResource Surface}"
                                BorderBrush="{StaticResource Border}"
                                BorderThickness="1"
                                CornerRadius="10"
                                Margin="0,0,12,12">
                            <Grid Margin="16">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel>
                                    <ContentPresenter/>
                                    <TextBlock x:Name="sub"
                                               Text="{TemplateBinding Tag}"
                                               Foreground="{StaticResource Muted}"
                                               FontWeight="Normal"
                                               FontSize="12"
                                               Margin="0,5,0,0"
                                               TextWrapping="Wrap"/>
                                </StackPanel>

                                <Border x:Name="box"
                                        Grid.Column="1"
                                        Width="20"
                                        Height="20"
                                        CornerRadius="5"
                                        BorderBrush="#767676"
                                        BorderThickness="1"
                                        Background="#000000"
                                        VerticalAlignment="Top"
                                        Margin="14,0,0,0">
                                    <TextBlock x:Name="tick"
                                               Text="✓"
                                               Foreground="#000000"
                                               FontWeight="Bold"
                                               FontSize="14"
                                               HorizontalAlignment="Center"
                                               VerticalAlignment="Center"
                                               Visibility="Collapsed"/>
                                </Border>
                            </Grid>
                        </Border>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="card" Property="BorderBrush" Value="#767676"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="card" Property="BorderBrush" Value="#fafafa"/>
                                <Setter TargetName="box" Property="Background" Value="#fafafa"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="#fafafa"/>
                                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="190"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0"
                Background="#000000"
                BorderBrush="#1a1a1a"
                BorderThickness="0,0,1,0">
            <Grid Margin="14">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Margin="8,10,8,24">
                    <TextBlock Text="files"
                               Foreground="#fafafa"
                               FontSize="24"
                               FontWeight="SemiBold"/>
                    <TextBlock Text="windows setup"
                               Foreground="#767676"
                               FontSize="12"
                               Margin="0,2,0,0"/>
                </StackPanel>

                <StackPanel Grid.Row="1">
                    <Button x:Name="navInstall" Style="{StaticResource NavButton}" Content="install"/>
                    <Button x:Name="navRuntimes" Style="{StaticResource NavButton}" Content="runtimes"/>
                    <Button x:Name="navTools" Style="{StaticResource NavButton}" Content="tools"/>
                </StackPanel>

                <TextBlock Grid.Row="2"
                           Text="matt files"
                           Foreground="#575757"
                           HorizontalAlignment="Center"
                           Margin="0,0,0,8"/>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="28,22,28,22">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid x:Name="pageInstall">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="install"
                                   FontSize="28"
                                   FontWeight="SemiBold"/>
                        <TextBlock Text="choose the apps you want on this pc."
                                   Foreground="#a5a5a5"
                                   FontSize="13"
                                   Margin="0,4,0,22"/>

                        <TextBlock Text="portable"
                                   FontSize="14"
                                   FontWeight="SemiBold"
                                   Foreground="#d6d6d6"
                                   Margin="0,0,0,10"/>

                        <UniformGrid Columns="2">
                            <CheckBox x:Name="chk1" Style="{StaticResource CardCheck}" Content="obs studio" Tag="portable • replay buffer • startup tray"/>
                            <CheckBox x:Name="chk2" Style="{StaticResource CardCheck}" Content="mpv" Tag="portable media player"/>
                            <CheckBox x:Name="chk3" Style="{StaticResource CardCheck}" Content="losslesscut" Tag="portable lossless editor"/>
                        </UniformGrid>

                        <TextBlock Text="applications"
                                   FontSize="14"
                                   FontWeight="SemiBold"
                                   Foreground="#d6d6d6"
                                   Margin="0,10,0,10"/>

                        <UniformGrid Columns="2">
                            <CheckBox x:Name="chk4" Style="{StaticResource CardCheck}" Content="everything" Tag="fast file search"/>
                            <CheckBox x:Name="chk5" Style="{StaticResource CardCheck}" Content="bulk crap uninstaller" Tag="clean application removal"/>
                            <CheckBox x:Name="chk6" Style="{StaticResource CardCheck}" Content="greenshot" Tag="screenshot utility"/>
                            <CheckBox x:Name="chk7" Style="{StaticResource CardCheck}" Content="notepad++" Tag="text and code editor"/>
                            <CheckBox x:Name="chk8" Style="{StaticResource CardCheck}" Content="microsoft office" Tag="configured office deployment"/>
                        </UniformGrid>
                    </StackPanel>
                </ScrollViewer>
            </Grid>

            <Grid x:Name="pageRuntimes" Visibility="Collapsed">
                <StackPanel>
                    <TextBlock Text="runtimes"
                               FontSize="28"
                               FontWeight="SemiBold"/>
                    <TextBlock Text="common runtime packages used by windows applications and games."
                               Foreground="#a5a5a5"
                               FontSize="13"
                               Margin="0,4,0,22"/>

                    <CheckBox x:Name="chk9"
                              Style="{StaticResource CardCheck}"
                              Content="visual c++ redistributables 2005-2026"
                              Tag="installs x86 and x64 runtimes silently"/>
                </StackPanel>
            </Grid>

            <Grid x:Name="pageTools" Visibility="Collapsed">
                <StackPanel>
                    <TextBlock Text="tools"
                               FontSize="28"
                               FontWeight="SemiBold"/>
                    <TextBlock Text="standalone utilities and driver tools."
                               Foreground="#a5a5a5"
                               FontSize="13"
                               Margin="0,4,0,22"/>

                    <CheckBox x:Name="chk10"
                              Style="{StaticResource CardCheck}"
                              Content="nvcleanstall 1.19.0"
                              Tag="desktop tool • imports saved previous-settings preset"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="1"
                    Background="#1a1a1a"
                    BorderBrush="#292929"
                    BorderThickness="1"
                    CornerRadius="12"
                    Margin="0,18,0,0">
                <Grid Margin="16">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <DockPanel Grid.Row="0">
                        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                            <Button x:Name="selectAllButton" Content="select all"/>
                            <Button x:Name="clearButton" Content="clear"/>
                        </StackPanel>

                        <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
                            <Button x:Name="closeButton" Content="close"/>
                            <Button x:Name="installButton"
                                    Content="install selected"
                                    Style="{StaticResource PrimaryButton}"/>
                        </StackPanel>
                    </DockPanel>

                    <TextBlock x:Name="speedText"
                               Grid.Row="1"
                               Text="download speed: -- mb/s"
                               HorizontalAlignment="Center"
                               Foreground="#d6d6d6"
                               FontFamily="Consolas"
                               FontSize="14"
                               FontWeight="SemiBold"
                               Margin="0,8,0,5"/>

                    <ProgressBar x:Name="progress"
                                 Grid.Row="2"
                                 Height="7"
                                 Minimum="0"
                                 Maximum="100"
                                 Value="0"
                                 Foreground="#fafafa"
                                 Background="#292929"
                                 Margin="2,0,2,10"/>

                    <TextBox x:Name="statusBox"
                             Grid.Row="3"
                             Height="92"
                             Background="#000000"
                             Foreground="#d6d6d6"
                             BorderBrush="#292929"
                             BorderThickness="1"
                             FontFamily="Consolas"
                             FontSize="12"
                             IsReadOnly="True"
                             VerticalScrollBarVisibility="Auto"
                             Text="ready. select one or more items, then click install selected."/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@


$reader = new-object system.xml.xmlnodereader $xaml
$window = [windows.markup.xamlreader]::load($reader)

$script:navinstall = $window.findname("navInstall")
$script:navruntimes = $window.findname("navRuntimes")
$script:navtools = $window.findname("navTools")

$script:pageinstall = $window.findname("pageInstall")
$script:pageruntimes = $window.findname("pageRuntimes")
$script:pagetools = $window.findname("pageTools")

$script:statusbox = $window.findname("statusBox")
$script:progress = $window.findname("progress")
$script:speedtext = $window.findname("speedText")
$script:installbutton = $window.findname("installButton")
$script:selectallbutton = $window.findname("selectAllButton")
$script:clearbutton = $window.findname("clearButton")
$script:closebutton = $window.findname("closeButton")

$script:checkboxes = @{}

1..10 | foreach-object {
    $script:checkboxes[$_] = $window.findname("chk$_")
}

function set-page($page, $button) {
    $script:pageinstall.visibility = "Collapsed"
    $script:pageruntimes.visibility = "Collapsed"
    $script:pagetools.visibility = "Collapsed"

    $script:navinstall.foreground = "#a5a5a5"
    $script:navruntimes.foreground = "#a5a5a5"
    $script:navtools.foreground = "#a5a5a5"

    $page.visibility = "Visible"
    $button.foreground = "#fafafa"
}

function set-ui-enabled($enabled) {
    1..10 | foreach-object {
        $script:checkboxes[$_].isenabled = $enabled
    }

    $script:selectallbutton.isenabled = $enabled
    $script:clearbutton.isenabled = $enabled
    $script:installbutton.isenabled = $enabled
    $script:navinstall.isenabled = $enabled
    $script:navruntimes.isenabled = $enabled
    $script:navtools.isenabled = $enabled
    $script:closebutton.isenabled = $enabled
}

set-page $script:pageinstall $script:navinstall

$script:navinstall.add_click({
    if (!$script:busy) {
        set-page $script:pageinstall $script:navinstall
    }
})

$script:navruntimes.add_click({
    if (!$script:busy) {
        set-page $script:pageruntimes $script:navruntimes
    }
})

$script:navtools.add_click({
    if (!$script:busy) {
        set-page $script:pagetools $script:navtools
    }
})


function set-final-summary($selected, $states, $failed) {
    set-download-speed 0 0 $false
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
    $script:progress.isindeterminate = $false
    $script:progress.value = 100
    do-events
}

function invoke-install($selected) {
    $script:downloaderrors = @{}
    $script:installerrors = @{}
    $script:locations = @{}
    set-download-speed 0 0 $false

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
            "select at least one item first.",
            "files",
            "ok",
            "information"
        ) | out-null

        return
    }

    $script:busy = $true
    set-ui-enabled $false
    $script:statusbox.text = "starting..."
    $script:progress.isindeterminate = $false
    $script:progress.value = 0
    set-download-speed 0 0 $false
    do-events

    try {
        invoke-install $selected
    }
    catch {
        $script:statusbox.text = "installer error:`r`n`r`n$($_.exception.message)"
        $script:statusbox.scrolltoend()
        $script:progress.isindeterminate = $false
    }
    finally {
        $script:busy = $false
        set-ui-enabled $true
        do-events
    }
})

$window.showdialog() | out-null
