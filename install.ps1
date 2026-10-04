$erroractionpreference = "stop"

if ([threading.thread]::currentthread.apartmentstate -ne "STA") {
    $self = $myinvocation.mycommand.path

    if ($self) {
        start-process powershell.exe -argumentlist "-sta -noprofile -executionpolicy bypass -file `"$self`""
    }
    else {
        [system.windows.messagebox]::show(
            "Run this demo from a local .ps1 file so it can relaunch in STA mode.",
            "files demo",
            "ok",
            "information"
        ) | out-null
    }

    exit
}

add-type -assemblyname presentationframework
add-type -assemblyname presentationcore
add-type -assemblyname windowsbase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="files - ui demo"
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
                           Text="demo build"
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
                             Text="ready. this is a visual demo; no software will be installed."/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

$reader = new-object system.xml.xmlnodereader $xaml
$window = [windows.markup.xamlreader]::load($reader)

$navInstall = $window.findname("navInstall")
$navRuntimes = $window.findname("navRuntimes")
$navTools = $window.findname("navTools")

$pageInstall = $window.findname("pageInstall")
$pageRuntimes = $window.findname("pageRuntimes")
$pageTools = $window.findname("pageTools")

$selectAllButton = $window.findname("selectAllButton")
$clearButton = $window.findname("clearButton")
$closeButton = $window.findname("closeButton")
$installButton = $window.findname("installButton")
$speedText = $window.findname("speedText")
$progress = $window.findname("progress")
$statusBox = $window.findname("statusBox")

$checks = @{}
1..10 | foreach-object {
    $checks[$_] = $window.findname("chk$_")
}

function set-page($page, $button) {
    $pageInstall.visibility = "Collapsed"
    $pageRuntimes.visibility = "Collapsed"
    $pageTools.visibility = "Collapsed"

    $navInstall.foreground = "#a5a5a5"
    $navRuntimes.foreground = "#a5a5a5"
    $navTools.foreground = "#a5a5a5"

    $page.visibility = "Visible"
    $button.foreground = "#fafafa"
}

set-page $pageInstall $navInstall

$navInstall.add_click({ set-page $pageInstall $navInstall })
$navRuntimes.add_click({ set-page $pageRuntimes $navRuntimes })
$navTools.add_click({ set-page $pageTools $navTools })

$selectAllButton.add_click({
    1..10 | foreach-object {
        $checks[$_].ischecked = $true
    }
})

$clearButton.add_click({
    1..10 | foreach-object {
        $checks[$_].ischecked = $false
    }
})

$closeButton.add_click({
    $window.close()
})

$timer = new-object windows.threading.dispatchertimer
$timer.interval = [timespan]::frommilliseconds(170)

$demoStep = 0
$timer.add_tick({
    $demoStep++

    $value = [math]::min(100, $demoStep * 2)
    $progress.value = $value

    if ($value -lt 42) {
        $speed = 22 + (($demoStep * 7) % 18)
        $speedText.text = ("download speed: {0:N2} mb/s" -f $speed)
        $statusBox.text = "downloading selected files...`r`nobs                         downloading`r`nmpv                         downloading"
    }
    elseif ($value -lt 78) {
        $speedText.text = "download speed: -- mb/s"
        $statusBox.text = "installing selected apps...`r`nobs                         extracting`r`nmpv                         done"
    }
    elseif ($value -lt 100) {
        $speedText.text = "download speed: -- mb/s"
        $statusBox.text = "finishing...`r`nobs                         done`r`nmpv                         done"
    }
    else {
        $timer.stop()
        $speedText.text = "download speed: -- mb/s"
        $statusBox.text = "demo complete.`r`n`r`nno files were downloaded or installed."
        $installButton.isenabled = $true
        $selectAllButton.isenabled = $true
        $clearButton.isenabled = $true
    }
})

$installButton.add_click({
    $selected = @(
        1..10 | where-object {
            $checks[$_].ischecked -eq $true
        }
    )

    if (!$selected.count) {
        [system.windows.messagebox]::show(
            "Select at least one item first.",
            "files demo",
            "ok",
            "information"
        ) | out-null
        return
    }

    $demoStep = 0
    $progress.value = 0
    $installButton.isenabled = $false
    $selectAllButton.isenabled = $false
    $clearButton.isenabled = $false
    $timer.start()
})

$window.showdialog() | out-null
