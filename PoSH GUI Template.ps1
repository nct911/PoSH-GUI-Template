<#

Program: PoSH GUI Template
Modified Date: 2023-06-07
Author: Jeremy Crabtree <jcrabtree at nct911 org> / <jeremylc at gmail>
Purpose: Use this template to create new GUI tools.
Copyright 2023 NCT 9-1-1 

#>

#CREATE HASHTABLE AND RUNSPACE FOR GUI
$WPFGui = [hashtable]::Synchronized(@{ })
$newRunspace = [runspacefactory]::CreateRunspace()
$newRunspace.ApartmentState = "STA"
$newRunspace.ThreadOptions = "UseNewThread"
$newRunspace.Open()
$newRunspace.SessionStateProxy.SetVariable("WPFGui", $WPFGui)

#Create master runspace andadd code
$psCmd = [System.Management.Automation.PowerShell]::Create().AddScript( {

        # Add WPF and Windows Forms assemblies. This must be done inside the runspace that contains the primary program code.
        try {
            Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Drawing, system.windows.forms, System.Windows.Controls.Ribbon, System.DirectoryServices.AccountManagement
        }
        catch {
            Throw 'Failed to load Windows Presentation Framework assemblies.'
        }

        try {
            Add-Type -Name Win32Util -Namespace System -MemberDefinition @'
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("User32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);

[DllImport("user32.dll", SetLastError = true)] 
public static extern int GetWindowLong(IntPtr hWnd, int nIndex); 

[DllImport("user32.dll")] 
public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

[DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[DllImport("user32.dll")]
public static extern bool BringWindowToTop(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);

const UInt32 SWP_NOSIZE = 0x0001;
const UInt32 SWP_NOMOVE = 0x0002;
const UInt32 SWP_NOACTIVATE = 0x0010;
const UInt32 SWP_SHOWWINDOW = 0x0040;

static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
static readonly IntPtr HWND_TOP = new IntPtr(0);
static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

public static void SetBottom(IntPtr hWindow)
{
    SetWindowPos(hWindow, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

public static void SetTop(IntPtr hWindow)
{
    SetWindowPos(hWindow, HWND_TOP, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}
'@
        }
        catch {
            Write-Verbose "Win32Util already defined"
        }

        #region Utility Functions

        # This is the list of functions to add to the InitialSessionState that is used for all Asynchronus Runsspaces
        $SessionFunctions = New-Object  System.Collections.ArrayList


        function Invoke-Async {
            <#
                .SYNOPSIS
                Runs code, with variables, asynchronously

                .DESCRIPTION
                This function runs the given code in an asynchronous runspace.
                This lets you process data in the background while leaving the UI responsive to input

                .PARAMETER Code
                The code to run in the runspace

                .PARAMETER Variables
                A hashtable containing variable names and values to pass into the runspace

                .EXAMPLE

                $AsyncParameters = @{
                    Variables = @{
                        Key1 = 'Value1'
                        Key2 = $SomeOtherVariable
                    }
                    Code = @{
                        Write-Host "Key1: $Key1`nKey2: $Key2"
                    }
                }
                Invoke-Async @AsyncParameters

                .NOTES
                It's more reliable to pass single values than copmlex objects duje to the way PowerShell handles value/reference passing with objects

                .INPUTS
                Variables, Code

                .OUTPUTS
                None
            #>
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [ScriptBlock]
                $Code,
                [Parameter(Mandatory = $false)]
                [hashtable]
                $Variables
            )
            # Add the above code to a runspace and execute it.
            $PSinstance = [powershell]::Create() #| Out-File -Append -FilePath $LogFile
            $PSinstance.Runspace = [runspacefactory]::CreateRunspace($InitialSessionState)
            $PSinstance.Runspace.ApartmentState = "STA"
            $PSinstance.Runspace.ThreadOptions = "UseNewThread"
            $PSinstance.Runspace.Open()
            if ($Variables) {
                # Pass in the specified variables from $VariableList
                $Variables.keys.ForEach({ 
                        $PSInstance.Runspace.SessionStateProxy.SetVariable($_, $Variables.$_)
                    })
            }
            $PSInstance.AddScript($Code)
            $PSinstance.BeginInvoke()
            $WPFGui.Error = $PSInstance.Streams.Error
        }
        $SessionFunctions.Add('Invoke-Async') | Out-Null
        Function New-WPFDialog() {
            <#
                .SYNOPSIS
                This neat little function is based on the one from Brian Posey's Article on Powershell GUIs

                .DESCRIPTION
                I re-factored it a bit to return the resulting XaML Reader and controls as a single, named collection.

                .PARAMETER XamlData
                XamlData - A string containing valid XaML data

                .EXAMPLE

                $MyForm = New-WPFDialog -XamlData $XaMLData
                $MyForm.Exit.Add_Click({...})
                $null = $MyForm.UI.Dispatcher.InvokeAsync{$MyForm.UI.ShowDialog()}.Wait()

                .NOTES
                Place additional notes here.

                .LINK
                http://www.windowsnetworking.com/articles-tutorials/netgeneral/building-powershell-gui-part2.html

                .INPUTS
                XamlData - A string containing valid XaML data

                .OUTPUTS
                a collection of WPF GUI objects.
            #>

            Param(
                [Parameter(Mandatory = $True, HelpMessage = 'XaML Data defining a WPF <window>', Position = 1)]
                [string]$XamlData,
                [Parameter(Mandatory = $False, HelpMessage = 'XaML Data defining WPF <Window.Resources', Position = 2)]
                [string]$Resources
                #[Parameter(Mandatory = $True, HelpMessage = 'Synchroinize hashtable to hold UI elements', Position = 2)]
                #[ref]$WPFGui
            )
            # Create an XML Object with the XaML data in it
            [xml]$xmlWPF = $XamlData

            #If a Resource Dictionary has been included, import and append it to our Window
            if ( -not [System.String]::IsNullOrEmpty( $Resources )) {
                [xml]$xmlResourceWPF = $Resources
                Foreach ($ChildNode in $xmlResourceWPF.ResourceDictionary.ChildNodes) {
            ($ImportNode = $xmlWPF.ImportNode($ChildNode, $true)) | Out-Null
                    $xmlWPF.Window.'Window.Resources'.AppendChild($ImportNode) | Out-Null
                }
            }

            # Create the XAML reader using a new XML node reader, UI is the only hard-coded object name here
            $XaMLReader = New-Object System.Collections.Hashtable
            $XaMLReader.Add('UI', ([Windows.Markup.XamlReader]::Load((new-object -TypeName System.Xml.XmlNodeReader -ArgumentList $xmlWPF)))) | Out-Null

            # Create hooks to each named object in the XAML reader
            $Elements = $xmlWPF.SelectNodes('//*[@Name]')
            ForEach ( $Element in $Elements ) {
                $VarName = $Element.Name
                $VarValue = $XaMLReader.UI.FindName($Element.Name)
                $XaMLReader.Add($VarName, $VarValue) | Out-Null
            }
            return $XaMLReader
        }
        $SessionFunctions.Add('New-WPFDialog') | Out-Null
        Function Set-Blur () {
            <#
                .SYNOPSIS
                Blurs the MainWindow

                .DESCRIPTION


                .PARAMETER On
                Turn blur on

                .PARAMETER Off
                Turn blur off

                .EXAMPLE

                Set-Blur -On

                .NOTES

                .INPUTS
                none

                .OUTPUTS
                None
            #>

            [CmdletBinding()]
            param (
                [Parameter(ParameterSetName = 'On')]
                [switch]
                $On,
                [Parameter(ParameterSetName = 'Off')]
                [switch]
                $Off
            )
            Switch ($PSCmdlet.ParameterSetName) {
                'On' {
                    $WPFGui.MainGrid.Effect.Radius = 10
                }
                'Off' {
                    $WPFGui.MainGrid.Effect.Radius = 0
                }
            }
        }
        $SessionFunctions.Add('Set-Blur') | Out-Null
        function Copy-Object {
            <#
                .SYNOPSIS
                Copies a PSObject

                .DESCRIPTION
                Copies an object to new memory. Sometimes you really need to duplicate an object, rather than just create a new pointer to it. This serializes an object then deserializes it to new memory as a brute force mechanism to copy it.

                .PARAMETER InputObject
                The Object to be copied

                .EXAMPLE

                $NewCopy = Copy-Object $OldObject

                .NOTES

                .INPUTS
                An object

                .OUTPUTS
                A copy of an object
            #>
            param (
                $InputObject
            )
            $SerialObject = [System.Management.Automation.PSSerializer]::Serialize($InputObject)
            return [System.Management.Automation.PSSerializer]::Deserialize($SerialObject)
        }
        $SessionFunctions.Add('Copy-Object') | Out-Null
        Function New-MessageDialog() {
            <#
                .SYNOPSIS
                Displays a Windows 11 styled MEssage Dialog

                .DESCRIPTION
                This is a utility function to display a baisc information, error, or simple input window in a Windows 11 style.

                .PARAMETER DialogTitle
                'Dialog Title'

                .PARAMETER H1
                'Major Header'

                .PARAMETER DialogText
                'Message Text'

                .PARAMETER CancelText
                'Cancel Text'

                .PARAMETER ConfirmText
                'Confirm Text'

                .PARAMETER Beep
                'Plays sound if set'

                .PARAMETER GetInput
                'Shows input TextBox if set'

                .PARAMETER IsError
                'Shows error icon if set'

                .PARAMETER IsAsync
                'Process asynchronously when set'

                .PARAMETER Owner'
                'Owner Window, required when this is a child'

                .EXAMPLE
                $NewDialog = @{
                    DialogTitle = 'Example Dialog' 
                    H1          = "This is a pop-up dialog"
                    DialogText  = "Dialog text should go here"
                    ConfirmText = 'Continue'
                    GetInput    = $false
                    Beep        = $true
                    IsError     = $true
                    Owner       = $WPFGui.UI
                }
                $Dialog = New-MessageDialog @NewDialog

                .NOTES

                .INPUTS
                None

                .OUTPUTS
                DialogResult, nd Text if requested
            #>

            Param(
                [Parameter(Mandatory = $True, HelpMessage = 'Dialog Title', Position = 1)]
                [string]$DialogTitle,

                [Parameter(Mandatory = $True, HelpMessage = 'Major Header', Position = 2)]
                [string]$H1,

                [Parameter(Mandatory = $True, HelpMessage = 'Message Text', Position = 3)]
                [string]$DialogText,

                [Parameter(Mandatory = $false, HelpMessage = 'Cancel Text', Position = 4)]
                [string]$CancelText = $null,

                [Parameter(Mandatory = $True, HelpMessage = 'Confirm Text', Position = 5)]
                [string]$ConfirmText,

                [Parameter(Mandatory = $false, HelpMessage = 'Plays sound if set', Position = 6)]
                [switch]$Beep,

                [Parameter(Mandatory = $false, HelpMessage = 'Shows input TextBox if set', Position = 7)]
                [switch]$GetInput,

                [Parameter(Mandatory = $false, HelpMessage = 'Shows error icon if set', Position = 8)]
                [switch]$IsError,

                [Parameter(Mandatory = $false, HelpMessage = 'Process asynchronously when set', Position = 9)]
                [switch]$IsAsync,

                [Parameter(Mandatory = $true, HelpMessage = 'Owner Window, required when this is a child', Position = 10)]
                [PSObject]$Owner


            )

            $Dialog = New-WPFDialog -XamlData @'
<Window x:Class="System.Windows.Window"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:errordialogXaML"
        Name="MainWindow"
        Title="__DIALOGTITLE__"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        SizeToContent="WidthAndHeight"
        Width="420"
        MinWidth="420"
        MaxWidth="700"
        Height="212"
        MinHeight="212"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Padding="20"
        Margin="0"
        ShowInTaskbar="False">
    <Window.Resources>
        
        <!-- Button Template. This duplicates the one from ControlTemplates.XaML It's here to make sure this dialog is self contained -->
        <SolidColorBrush x:Key="Button.Static.Background" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.Static.Border" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.MouseOver.Background" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.MouseOver.Border" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.Pressed.Background" Color="#FF606060" />
        <SolidColorBrush x:Key="Button.Pressed.Border" Color="#FF606060" />
        <SolidColorBrush x:Key="Button.Disabled.Background" Color="#FFF0F0F0" />
        <SolidColorBrush x:Key="Button.Disabled.Border" Color="#FFADB2B5" />
        <SolidColorBrush x:Key="Button.Disabled.Foreground" Color="#FF838383" />
        <SolidColorBrush x:Key="Button.Default.Foreground" Color="White" />
        <SolidColorBrush x:Key="Button.Default.Background" Color="#FF005FB8" />
        <SolidColorBrush x:Key="Button.Default.Border" Color="#FF005FB8" />
        <Style TargetType="{x:Type Button}">
            <Setter Property="BorderBrush" Value="{StaticResource Button.Static.Border}" />
            <Setter Property="Background" Value="{StaticResource Button.Static.Border}" />
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Padding" Value="8,0,8,4" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Background="{TemplateBinding Background}" SnapsToDevicePixels="true" CornerRadius="4" Padding="0" Margin="0">
                            <ContentPresenter x:Name="contentPresenter" Focusable="False" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsDefault" Value="true">
                    <Setter Property="BorderBrush" Value="{StaticResource Button.Default.Border}" />
                    <Setter Property="Background" Value="{StaticResource Button.Default.Background}" />
                    <Setter Property="Foreground" Value="{StaticResource Button.Default.Foreground}" />
                </Trigger>
                <Trigger Property="IsMouseOver" Value="true">
                    <Setter Property="Background" Value="{StaticResource Button.MouseOver.Background}" />
                    <Setter Property="BorderBrush" Value="{StaticResource Button.MouseOver.Border}" />
                </Trigger>
                <Trigger Property="IsPressed" Value="true">
                    <Setter Property="Background" Value="{StaticResource Button.Pressed.Background}" />
                    <Setter Property="BorderBrush" Value="{StaticResource Button.Pressed.Border}" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="false">
                    <Setter Property="Background" Value="{StaticResource Button.Disabled.Background}" />
                    <Setter Property="BorderBrush" Value="{StaticResource Button.Disabled.Background}" />
                    <Setter Property="TextElement.Foreground" Value="{StaticResource Button.Disabled.Foreground}" />
                </Trigger>

            </Style.Triggers>
        </Style>
        
        <!-- TextBox Template. Also a duplicate from ControlTemplates.XaML and included to keep this self-contained. -->
        <SolidColorBrush x:Key="TextBox.Static.Border" Color="#7F7A7A7A" />
        <SolidColorBrush x:Key="TextBox.MouseOver.Border" Color="#FF005FB8" />
        <SolidColorBrush x:Key="TextBox.Focus.Border" Color="#FF005FB8" />
        <Style TargetType="{x:Type TextBox}">
            <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.WindowBrushKey}}" />
            <Setter Property="BorderBrush" Value="{StaticResource TextBox.Static.Border}" />
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
            <Setter Property="BorderThickness" Value="0,0,0,1" />
            <Setter Property="FontFamily" Value="Segoe UI" />
            <Setter Property="KeyboardNavigation.TabNavigation" Value="None" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="AllowDrop" Value="true" />
            <Setter Property="ScrollViewer.PanningMode" Value="VerticalFirst" />
            <Setter Property="Stylus.IsFlicksEnabled" Value="False" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TextBox}">
                        <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Background="{TemplateBinding Background}" SnapsToDevicePixels="True" CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Focusable="false" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="false">
                                <Setter Property="Opacity" TargetName="border" Value="0.56" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="true">
                                <Setter Property="Opacity" TargetName="border" Value="1" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="true">
                                <Setter Property="BorderBrush" TargetName="border" Value="{StaticResource TextBox.MouseOver.Border}" />
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="true">
                                <Setter Property="BorderBrush" TargetName="border" Value="{StaticResource TextBox.Focus.Border}" />
                                <Setter Property="BorderThickness" TargetName="border" Value="0,0,0,2" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <MultiTrigger>
                    <MultiTrigger.Conditions>
                        <Condition Property="IsInactiveSelectionHighlightEnabled" Value="true" />
                        <Condition Property="IsSelectionActive" Value="false" />
                    </MultiTrigger.Conditions>
                    <Setter Property="SelectionBrush" Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightBrushKey}}" />
                </MultiTrigger>
            </Style.Triggers>
        </Style>

        <!-- A small styler to make the window border respond to being focused or unfocused -->
        <Style TargetType="Window">
            <Style.Triggers>
                <Trigger Property="IsActive" Value="False">
                    <Setter Property="BorderBrush" Value="#FFAAAAAA" />
                </Trigger>
                <Trigger Property="IsActive" Value="True">
                    <Setter Property="BorderBrush" Value="#FF005FB8" />
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="2" CornerRadius="8" />
    </WindowChrome.WindowChrome>

    <Border BorderThickness="1" BorderBrush="{Binding Path=BorderBrush, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" Background="White" CornerRadius="8" Margin="10,10,10,10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="10" ShadowDepth="5" Color="#FF959595" Opacity="0.7" />
        </Border.Effect>
        <Grid>
            <TextBlock Name="DialogTitle" Text="__DIALOGTITLE__" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="8,6,0,0" />
            <DockPanel Margin="22,48,24,24">
                <TextBlock DockPanel.Dock="Top" Name="H1" Text="__H1__" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0" FontSize="27" />
                <DockPanel DockPanel.Dock="Top">
                    <Viewbox Name="ErrorIcon" DockPanel.Dock="Left" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="32" Stretch="Uniform" HorizontalAlignment="Center" Margin="0" Visibility="Collapsed">
                        <Canvas Name="svg8" Width="8.4666665" Height="8.466677">
                            <Path xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Name="path4530" Fill="#FFDA4453" StrokeThickness="0.38186711" Stroke="#FFDA4453" StrokeLineJoin="Miter" StrokeStartLineCap="Flat" StrokeEndLineCap="Flat">
                                <Path.Data>
                                    <PathGeometry Figures="m 4.233334 0.19093356 c -2.2325595 0 -4.04240044 1.80984004 -4.04240044 4.04240004 0 2.23257 1.80984094 4.04241 4.04240044 4.04241 2.2325597 0 4.0423991 -1.80984 4.0423991 -4.04241 0 -2.23256 -1.8098394 -4.04240004 -4.0423991 -4.04240004 z m -1.9241831 1.15498004 1.9241831 1.92418 1.9241815 -1.92418 0.963223 0.96322 -1.9241829 1.92419 1.9241829 1.92418 -0.963223 0.96321 -1.9241815 -1.92417 -1.9241831 1.92417 -0.9632231 -0.96321 1.9241831 -1.92418 -1.9241831 -1.92419 z" FillRule="NonZero" />
                                </Path.Data>
                            </Path>
                        </Canvas>
                    </Viewbox>
                    <TextBlock DockPanel.Dock="Left" Name="DialogText" Text="__DIALOGTEXT__" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,8,0,0" FontSize="15" />
                </DockPanel>
                <TextBox DockPanel.Dock="Top" Name="Input" Visibility="Hidden" Margin="0,10" FontSize="15" />
                <StackPanel DockPanel.Dock="Bottom" Margin="0" HorizontalAlignment="Right" VerticalAlignment="Bottom" Orientation="Horizontal">
                    <Button Name="CancelButton" Content="__CANCELTEXT__" HorizontalAlignment="Right" Margin="0,0,24,0" VerticalAlignment="Bottom" FontSize="15" FontFamily="Segoe UI Semibold" />
                    <Button Name="ConfirmButton" Content="__CONFIRMTEXT__" HorizontalAlignment="Right" Margin="0" VerticalAlignment="Bottom" IsDefault="True" FontSize="15" FontFamily="Segoe UI Semibold" />
                </StackPanel>
            </DockPanel>
        </Grid>
    </Border>
</Window>
'@

            if ($Owner) {
                if ($IsAsync) {
                    $Owner.Dispatcher.invoke([action] {
                            $Dialog.UI.Owner = $Owner
                        })
                }
                else {
                    $Dialog.UI.Owner = $Owner
                }
            }

            $Dialog.MainWindow.Title = $DialogTitle
            $Dialog.DialogTitle.Text = $DialogTitle
            $Dialog.H1.Text = $H1
            $Dialog.DialogText.Text = $DialogText
            if ($CancelText) {
                $Dialog.CancelButton.Content = $CancelText
            }
            else {
                $Dialog.CancelButton.Visibility = 'hidden'
            }
            $Dialog.ConfirmButton.Content = $ConfirmText
            if ($IsError) {
                $Dialog.ErrorIcon.Visibility = 'Visible'
                $Dialog.DialogText.Margin = '8,8,0,0'
            }

            if ($GetInput) {
                $Dialog.Input.Visibility = 'Visible'
            }

            $Dialog.Add('Result', [System.Windows.Forms.DialogResult]::Cancel) | Out-Null


            $Dialog.ConfirmButton.add_Click( {
                    $Dialog.Result = [System.Windows.Forms.DialogResult]::OK
                    $Dialog.UI.Close()
                })
            $Dialog.CancelButton.Add_Click( {
                    $Dialog.Result = [System.Windows.Forms.DialogResult]::Cancel
                    $Dialog.UI.Close()
                })
            $Dialog.UI.add_ContentRendered( {
                    if ($Beep) {
                        [system.media.systemsounds]::Exclamation.play()
                    }
                })

            $null = $Dialog.UI.Dispatcher.InvokeAsync{ $Dialog.UI.ShowDialog() }.Wait()

            return @{
                DialogResult = $Dialog.Result
                Text         = $Dialog.Input.Text
            }
        }
        $SessionFunctions.Add('New-MessageDialog') | Out-Null
        function Write-Activity {
            <#
                .SYNOPSIS
                Write a colorized  entry into the specified RichTextBox

                .DESCRIPTION
                This is usually used to write an entry into a RichTexBox which is being used as an Activity Log.

                .PARAMETER Prefix
                The "prefix" text, usually program section or activity, to pre-pended to the row

                .PARAMETER Text
                The actual text to write

                .PARAMETER Stream
                The RichTextBox to write to

                .PARAMETER IsError
                If set, this is an error message, write everything in RED

                .EXAMPLE

                Write-Activity -Prefix 'PoSH GUI Template' -Text 'Example Activity Log Entry' -Stream 'Output'

                .NOTES
                If you change the name of $WPFGui, you'll need to change it here.

                .INPUTS
                Text

                .OUTPUTS
                None
            #>
            param (
                # Prefix text, describe which part is printing output
                [Parameter(Mandatory = $true)]
                [string]
                $Prefix,
                # Text to be printed
                [Parameter(Mandatory = $true)]
                [string]
                $Text,
                # Output stream to be used
                [Parameter(Mandatory = $true)]
                [string]
                $Stream,

                [switch]
                $IsError

            )
            $WPFGui.UI.Dispatcher.Invoke([action] {
                    $DateStamp = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
                    $TextRun = New-Object System.Windows.Documents.Run
                    $TextRun.Foreground = "Red"
                    $TextRun.Text = $DateStamp
                    $Paragraph = New-Object System.Windows.Documents.Paragraph($TextRun)

                    $TextRun = New-Object System.Windows.Documents.Run
                    $TextRun.Foreground = "#FF9A9A9A"
                    $TextRun.Text = ":"
                    $Paragraph.Inlines.Add($TextRun)
                    #$WPFGui."$Stream".AppendText($TextRun)

                    $TextRun = New-Object System.Windows.Documents.Run
                    $TextRun.Foreground = "#FF0078D7"
                    $TextRun.Text = $Prefix
                    $Paragraph.Inlines.Add($TextRun)
                    #                    $WPFGui."$Stream".AppendText($TextRun)

                    $TextRun = New-Object System.Windows.Documents.Run
                    $TextRun.Foreground = "#FF9A9A9A"
                    $TextRun.Text = ": "
                    $Paragraph.Inlines.Add($TextRun)
                    #                    $WPFGui."$Stream".AppendText($TextRun)

                    $TextRun = New-Object System.Windows.Documents.Run
                    if ( $IsError ) {
                        $TextRun.Foreground = "Red"
                    }
                    else {
                        $TextRun.Foreground = "Black"
                    }

                    $TextRun.Text = $Text
                    $Paragraph.Inlines.Add($TextRun) | Out-Null
                    #                    $WPFGui."$Stream".AppendText($TextRun)
                    $WPFGui."$Stream".Document.Blocks.Add($Paragraph)  | Out-Null
                    $WPFGui."$Stream".ScrollToEnd()
                })
        }
        $SessionFunctions.Add('Write-Activity') | Out-Null
        function Write-StatusBar {
            <#
                .SYNOPSIS
                Write text, and a progress percentage, to the StatusBar area

                .DESCRIPTION
                Writes Status text and progress to the StatusBar area.

                .PARAMETER Progress
                Progress Bar value, from 0-100

                .PARAMETER Text
                Status Text to display

                .EXAMPLE

                Write-StatusBar -Progress 25 -Text "We're a quarter of the way there."

                .NOTES
                If you change the name of $WPFGui, you'll need to change it here.

                .INPUTS
                Text

                .OUTPUTS
                None
            #>

            param (
                # Prefix text, describe which part is printing output
                [Parameter(Mandatory = $true)]
                [int]
                $Progress,
                # Text to be printed
                [Parameter(Mandatory = $true)]
                [string]
                $Text
            )
            $WPFGui.UI.Dispatcher.invoke([action] {
                    $WPFGui.Progress.Value = $Progress
                    $WPFGui.StatusText.Text = $Text
                })
        
        }
        $SessionFunctions.Add('Write-StatusBar') | Out-Null
        function Save-Screenshot {
            <#
                .SYNOPSIS
                Save a Screenshot of the specified screen(s)

                .DESCRIPTION
                Save a screenshot of the specified screen(s) in the specified format. Valid formats are BMP, JPG/JPEG, and PNG.

                .PARAMETER FilePath
                Filename to save to

                .PARAMETER Format
                An optional parameter to specify a specific format. If not set, then the format is guessed from FilePath

                .PARAMETER ScreenNumber
                An int specifying which screen to save.

                .PARAMETER AllScreens
                A switch to specify a capture of all screens.

                .EXAMPLE

                Save-ScreenShot -FilePath "ScreenShot.jpg" -Format 'JPG' -ScreenNumber = 0

                .NOTES
                If you change the name of $WPFGui, you'll need to change it here.

                .INPUTS
                None

                .OUTPUTS
                Screenshot
            #>
            param (
                [Parameter(Mandatory = $true)]
                [string]$FilePath,

                [Parameter(Mandatory = $false)]
                [ValidateSet("BMP", "JPG", "JPEG", "PNG", "Unspecified")]
                [string]$Format = "Unspecified",

                [Parameter(Mandatory = $false)]
                [ValidateScript({
                    ((0 -le $_) -and ( $_ -le (([System.Windows.Forms.Screen]::AllScreens).Count - 1) ))
                    })]
                [int16]$ScreenNumber,

                [Parameter(Mandatory = $false)]
                [Switch]$AllScreens
            )

            $ScreenList = [System.Windows.Forms.Screen]::AllScreens
            $Top = 0
            $Bottom = 0
            $Left = 0
            $Right = 0

            if ($AllScreens) {
                foreach ($CurrentScreen in $ScreenList) {
                    $Bounds = $CurrentScreen.Bounds
                    if ($Top -gt $Bounds.Top) {
                        $Top = $Bounds.Top
                    }
                    if ($Left -gt $Bounds.Left) {
                        $Left = $Bounds.Left
                    }
                    if ($Bottom -lt $Bounds.Bottom) {
                        $Bottom = $Bounds.Bottom
                    }
                    if ($Right -lt $Bounds.Right) {
                        $Right = $Bounds.Right
                    }
                }
                $Width = $Right - $Left
                $Height = $Bottom - $Top
            }
            else {
                $Left = $ScreenList[$ScreenNumber].Bounds.Left
                $Top = $ScreenList[$ScreenNumber].Bounds.Top
                $Right = $ScreenList[$ScreenNumber].Bounds.Right
                $Bottom = $ScreenList[$ScreenNumber].Bounds.Bottom
                $Width = $ScreenList[$ScreenNumber].Bounds.Width
                $Height = $ScreenList[$ScreenNumber].Bounds.Height
            }

            $Bounds = [Drawing.Rectangle]::FromLTRB($Left, $Top, $Right, $Bottom)
            $Bitmap = New-Object Drawing.Bitmap $Width, $Height
            $Graphics = [Drawing.Graphics]::FromImage($Bitmap)
            $Graphics.CopyFromScreen($Bounds.Location, [Drawing.Point]::Empty, $Bounds.Size)

            try {
                if ($Format -eq 'Unspecified') {
                    $Format = $FilePath.Split('.')[-1]
                }
            }
            catch {
                Write-Error "Unable to determine filetype from $FilePath"
            }

            $Bitmap.Save($FilePath, [System.Drawing.Imaging.ImageFormat]::$Format)

            $Graphics.Dispose()
            $Bitmap.Dispose()
        }
        $SessionFunctions.Add('Save-Screenshot') | Out-Null
        Function Get-FileName() {
            <#
                .SYNOPSIS
                Use a Win32 FileDialog to request a Filename from the user.

                .DESCRIPTION
                Shows a Win32 FileOpenDialog or FleSaveDialog to request a Filename from the User

                .PARAMETER Title
                The window Title

                .PARAMETER Filter
                The FileType filter, see Microsoft's documentation on this.

                .PARAMETER InitialDirectory
                The Initial Directory to display

                .PARAMETER FileName
                The default  FileName to select

                .PARAMETER Save
                A switch to indicate that this is a SAVE dialog and not an OPEN dialog.

                .EXAMPLE

                $FileNameParameters = @{
                    Title    = 'New Log File Name'
                    Filter   = 'LOG Files (*.LOG)|*.log|HTML Files (*.html)|*.html|RTF Files (*.rtf)|*.rtf'
                    FileName = "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
                    Save     = $true
                }
                $FileName = Get-FileName @FileNameParameters

                .NOTES
                

                .INPUTS
                Text

                .OUTPUTS
                FileName
            #>
            Param(
                [Parameter()][string]$Title = 'Open File',
                [Parameter()][string]$Filter = 'All Files (*.*)|*.*',
                [Parameter()][string]$InitialDirectory = "$($env:HOMEDRIVE)$($env:HOMEPATH)",
                [Parameter()][string]$FileName = 'File.log',
                [switch]$Save
            )
                
            $Result = $false
            # Setup and open an "Open File" Dialog
            If ( $Save ) {
                $FileDialog = New-Object Microsoft.Win32.SaveFileDialog
                $FileDialog.FileName = $FileName
            }
            else {
                $FileDialog = New-Object Microsoft.Win32.OpenFileDialog
            }
            $FileDialog.Title = $Title
            $FileDialog.filter = $Filter
            $FileDialog.initialDirectory = $InitialDirectory
            $FileDialog.AddExtension = $true
            $FileDialogResult = $FileDialog.ShowDialog($owner)
                
            #"OK clicked" status
            $DialogOK = [System.Windows.Forms.DialogResult]::OK
                
            if ($FileDialogResult -eq $DialogOK) {
                $Result = $FileDialog
            }
            return $Result.FileName
        }
        $SessionFunctions.Add('Get-FileName') | Out-Null
        Function Get-FolderName() {
            <#
                .SYNOPSIS
                (Ab)Use a Win32 FileOpenDialog to request a FolderName from the user.

                .DESCRIPTION
                Shows a Win32 FileOpenDialog to request a FolderName from the User

                .EXAMPLE

                $FolderName = Get-FolderName

                .NOTES

                .INPUTS
                None

                .OUTPUTS
                FolderName
            #>

            $Result = $false
            # Setup and open an "Open File" Dialog
            $FileDialog = New-Object Microsoft.Win32.OpenFileDialog
            $FileDialog.Filter = "Select Folder|(Select Folder)"
            $FileDialog.Title = "Select Folder"
            $FileDialog.FileName = "Select Folder"
            $FileDialog.CheckFileExists = $false
            $FileDialog.ValidateNames = $false
            $FileDialog.CheckPathExists = $true
            $FileDialogResult = $FileDialog.ShowDialog()

            if ($FileDialogResult) {
                $Result = $FileDialog.FileName.Replace('Select Folder', '')
            }
            return $Result
        }
        $SessionFunctions.Add('Get-FolderName') | Out-Null

        function ConvertFrom-FlowDocument {
            <#
                .SYNOPSIS
                Converts a FlowDocument to HTML

                .DESCRIPTION
                Converts a (simple) RichTextBox FlowDocument to HTML

                .PARAMETER Document
                The FlowDocument to Convert

                .PARAMETER Title
                The HTML page Title to use

                .PARAMETER Save
                A switch to indicate that this is a SAVE dialog and not an OPEN dialog.

                .EXAMPLE

                $html = ConvertFrom-FlowDocument -Document $Document -Title $Title

                .NOTES

                .INPUTS
                FlowDocument and Title

                .OUTPUTS
                HTML document
            #>
            param (
                [Parameter(Mandatory = $True, HelpMessage = 'System.Windows.Documents.FlowDocument to convert to HTML', Position = 1)]
                [System.Windows.Documents.FlowDocument]$Document,
                [Parameter(Mandatory = $false, HelpMessage = 'Document Title', Position = 2)]
                [string]$Title = ""
            )

            $html = @"
<html>
    <head>
        <title>
            $Title
        </title>
    </head>
    <body style=`"font-family: monospace;`">`n
    $($Document.Blocks.ForEach({
        $_.Inlines.Foreach({"        <span style=`"color:$($_.Foreground.Color.ToString().Replace('#FF','#'))`">$($_.Text)</span>"})
        "<br/>`n"
    }))
    </body>
</html>
"@
            return $html
        }
        $SessionFunctions.Add('ConvertFrom-FlowDocument') | Out-Null

        function Save-FlowDocument {
            <#
                .SYNOPSIS
                Saves a RichTextBox FlowDocument in the requested format - LOG, RTF, or HTML.

                .DESCRIPTION
                Saves a RichTextBox FlowDocument as Plain Text (LOG), RichText (RTF), or HTML

                .PARAMETER Document
                FlowDocument to Save

                .PARAMETER Format
                The File Format to use - TXT, RTF, or HTML

                .PARAMETER Title
                The HTML page Title to use

                .PARAMETER FileName
                The name of the file to write.

                .EXAMPLE

                Save-FlowDocument -Document $WPFGui.Output.Document -Format $Format -FileName $FileName -Title "Example logs $(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')"

                .NOTES

                .INPUTS
                FlowDocument and Title

                .OUTPUTS
                HTML document
            #>
            param (
                [Parameter(Mandatory = $True, HelpMessage = 'Windows FlowDocument', Position = 1)]
                [System.Windows.Documents.FlowDocument]$Document,

                [Parameter(Mandatory = $True, HelpMessage = 'Format to save - txt, html, or rtf', Position = 2)]
                [ValidateSet("TXT", "RTF", "HTML")]
                [string]$Format,

                [Parameter(Mandatory = $false, HelpMessage = 'HTML Document Title', Position = 3)]
                [string]
                $Title,

                [Parameter(Mandatory = $True, HelpMessage = 'Filename', Position = 4)]
                [string]
                $FileName
            )

            # The TextRange is used for the TXT and RTF formats because it has a built-in .Save() method.
            $TextRange = [System.Windows.Documents.TextRange]::new($Document.ContentStart, $Document.ContentEnd)

            # This is used for all three
            $FHand = [System.IO.FileStream]::new($FileName, 'OpenOrCreate')
            switch ($Format) {
                'txt' {
                    $TextRange.Save($FHand, [System.Windows.DataFormats]::Text)
                }
                'html' {
                    # Convert the FlowDocument to HTML, cast it to a collection of bytes and write it to FHand.
                    $html = ConvertFrom-FlowDocument -Document $Document -Title $Title
                    $htmlBytes = [byte[]][char[]]$html
                    $FHand.Write($htmlBytes, 0, $htmlBytes.Count)
                }
                'rtf' {
                    $TextRange.Save($FHand, [System.Windows.DataFormats]::Rtf)
                }
            }
            $FHand.Flush()
            $FHand.Close()
        }
        $SessionFunctions.Add('Save-FlowDocument') | Out-Null

        # Create an Initial Session State for the ASync runspace and add all the functions in $SessionFunctions to it.
        $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $SessionFunctions.ForEach({
                $SessionFunctionEntry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($_, (Get-Content Function:\$_))
                $InitialSessionState.Commands.Add($SessionFunctionEntry) | Out-Null
            })

        #endregion Utility Functions

        #region - Setup default values

        # Development Mode Toggle
        $DevMode = $false

        # Failure Sentry. We watch this to know whether we need to bail out before trying to show the main window. 
        $Failed = $false

        if ($DevMode) {
            # If DevMode is set, we should read the UI definitions from these paths. This is useful when editing the XaML in Blend or Visual Studio.
            $XaMLWindowPath = '<full path to>\MainWindow.xaml'
            $XaMLResourceDictionaryPath = '<full path to>\ControlTemplates.XaML'
            # Load the UI definition.
            $WPFXaML = Get-Content -Raw -Path $XaMLWindowPath
            $ResourceXaML = Get-Content -Raw -Path $XaMLResourceDictionaryPath

            # If DevMode is set, override normal pwd/cwd detection and set it explicitly.
            $ScriptPath = "<SomePath>"
        }
        else {
            if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") { 
                $ScriptPath = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
            }
            else { 
                $ScriptPath = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0]) 
                if (!$ScriptPath) { $ScriptPath = "." } 
            }
            $WPFXaML = @'
<!--

File: MainWindow.xaml
Modified Date: 2023-06-07
Author: Jeremy Crabtree <jcrabtree at nct911 org> / <jeremylc at gmail>
Purpose: Main Program window for the PoSH GUI Template
Copyright 2023 NCT 9-1-1

-->

<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
    xmlns:mc="http://schemas.openxmlformats.ouwpgrouprg/markup-compatibility/2006"
    xmlns:local="clr-namespace:PoSH_GUI_Template"
    xmlns:Themes="clr-namespace:Microsoft.Windows.Themes;assembly=PresentationFramework.Aero2"
    xmlns:dxe="http://schemas.devexpress.com/winfx/2008/xaml/editors"
    xmlns:dxg="http://schemas.devexpress.com/winfx/2008/xaml/grid"
    xmlns:col="clr-namespace:System.Collections;assembly=mscorlib"
    xmlns:sys="clr-namespace:System;assembly=mscorlib"

    x:Class="System.Windows.Window"
    Title="PoSH GUI Template"
    Width="800"
    MinWidth="800"
    Height="800"
    MinHeight="800"
    Name="DeploymentWindow"
    AllowsTransparency="True"
    BorderThickness="0"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanResize"
    WindowStyle="None"
    Background="Transparent">
    <Window.Resources><!-- Empty Resources --></Window.Resources>
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="{StaticResource TitleBarHeight}"
                      ResizeBorderThickness="{x:Static SystemParameters.WindowResizeBorderThickness}"
                      CornerRadius="8" />
    </WindowChrome.WindowChrome>
    <Window.OpacityMask>
        <VisualBrush Visual="{Binding ElementName=WinBorder}" />
    </Window.OpacityMask>
    <Border Name="WinBorder" BorderBrush="{Binding Path=BorderBrush, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" BorderThickness="1" CornerRadius="8" Background="#FFF3F3F3">
        <Border.Effect>
            <BlurEffect Radius="0" />
        </Border.Effect>
        <Grid Name="MainGrid" Background="Transparent">
            <Grid.Effect>
                <BlurEffect Radius="0" />
            </Grid.Effect>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="*" Name="MainRow" />
                <RowDefinition Height="20" />
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" Name="MenuColumn" />
                <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <!-- Titlebar dock -->
            <!--
                This is also a grid inside a border to keep the rounded corners.
            -->
            <Border Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" CornerRadius="8,8,0,0" BorderThickness="0">
                <DockPanel Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Height="{StaticResource TitleBarHeight}">
                    <!--
                         This is the "hamburger" button that opens the menu.  The open/close menu animation
                         is attached to the click event of this button as a trigger. 
                    -->
                    <Button DockPanel.Dock="Left" Name="MenuButton" Style="{StaticResource TitleBarButtonStyle}" Tag="Menu" HorizontalContentAlignment="Left" Width="46"  RenderTransformOrigin="0.5,0.5">
                        <Button.RenderTransform>
                            <TransformGroup>
                                <RotateTransform x:Name="MenuButtonRotate" Angle="0"/>
                            </TransformGroup>
                        </Button.RenderTransform>
                        <Button.Triggers>
                            <EventTrigger RoutedEvent="Button.Click">
                                <BeginStoryboard>
                                    <Storyboard Name="MenuOpen">
                                        <ParallelTimeline>
                                            <DoubleAnimation Name="MenuToggle"    Storyboard.TargetName="MenuBorder"       Storyboard.TargetProperty="Width" From="0" To="150" Duration="0:0:0.25" AutoReverse="False" >
                                                <DoubleAnimation.EasingFunction>
                                                    <QuinticEase EasingMode="EaseInOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Name="BurgerFlipper" Storyboard.TargetName="MenuButtonRotate" Storyboard.TargetProperty="Angle" From="0" To="90" Duration="0:0:0.25" AutoReverse="False" />
                                            <DoubleAnimation Name="BlurPanel"     Storyboard.TargetName="MainDockBlur"     Storyboard.TargetProperty="Radius" From="0" To="10"  Duration="0:0:0.25" AutoReverse="False" />
                                        </ParallelTimeline>
                                    </Storyboard>
                                </BeginStoryboard>
                            </EventTrigger>
                        </Button.Triggers>
                    </Button>

                    <!-- These are the standard Window control buttons -->
                    <Button DockPanel.Dock="Right" Name="CloseButton"    Style="{StaticResource TitleBarButtonStyle}" Tag="Close"    />
                    <Button DockPanel.Dock="Right" Name="MaximizeButton" Style="{StaticResource TitleBarButtonStyle}" Tag="Maximize" />
                    <Button DockPanel.Dock="Right" Name="RestoreButton"  Style="{StaticResource TitleBarButtonStyle}" Tag="Restore"  Visibility="Collapsed" />
                    <Button DockPanel.Dock="Right" Name="MinimizeButton" Style="{StaticResource TitleBarButtonStyle}" Tag="Minimize" />

                    <!-- Window TitleBar text -->
                    <TextBlock DockPanel.Dock="Left" Margin="8,0" Padding="0" Text="{Binding Title, RelativeSource={RelativeSource AncestorType=Window}}" TextAlignment="Center" HorizontalAlignment="Left" VerticalAlignment="Center" >
                        <TextBlock.Style>
                            <Style TargetType="TextBlock">
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding IsActive, RelativeSource={RelativeSource AncestorType=Window}}" Value="False">
                                        <Setter Property="Foreground" Value="#FFAAAAAA" />
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </TextBlock.Style>
                    </TextBlock>
                </DockPanel>
            </Border>

            <!-- Lefthand menu dock -->
            <Border Name="MenuBorder" Grid.Column="0" Grid.ColumnSpan="2" Grid.Row="1" Grid.RowSpan="1" Margin="0,0,0,0" Background="White" BorderThickness="0,1,1,1" CornerRadius="0,4,4,0" BorderBrush="#FFC8C8C8" Panel.ZIndex="10" HorizontalAlignment="Left" Width="0" >
                <Border.Effect>
                    <DropShadowEffect Opacity="0.5" BlurRadius="20"/>
                </Border.Effect>
                <DockPanel Name="MenuDock" Margin="0,0,0,0">
                    <StackPanel Margin="10,0,10,0" Orientation="Vertical">
                        <Button Name="SaveLogs" DockPanel.Dock="Top" Content="Save Logs" Style="{StaticResource MenuBarButtonStyle}" />
                        <Rectangle  Height="1" Margin="0,10,0,10" DockPanel.Dock="Top" Stroke="#FFC8C8C8" />
                        <Button Name="MenuExit" DockPanel.Dock="Top" Content="Exit" Style="{StaticResource MenuBarButtonStyle}" />
                    </StackPanel>
                </DockPanel>
            </Border>

            <!-- Main Tab Panel -->
            <!--
                Only the Border is part of the template. You can put anything you like in there. If you use a control that doesn't have a
                Windows 11 style, consider adding it to ControlTemplates.xaml  The content below is an example of multi-paned layout
                with various controls.
            -->
            <Border Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="0" BorderThickness="0">
                <DockPanel Margin="0">
                    <DockPanel.Effect >
                        <BlurEffect x:Name="MainDockBlur" Radius="0"/>
                    </DockPanel.Effect>
                    <DockPanel Margin="10,0,10,0" DockPanel.Dock="Top">
                        <StackPanel Orientation="Vertical" DockPanel.Dock="Left"
                                    HorizontalAlignment="Left" Width="200" VerticalAlignment="Top">
                            <GroupBox Margin="0" VerticalAlignment="Center"
                                        HorizontalAlignment="Stretch">
                                <GroupBox.Header>
                                    <StackPanel Orientation="Horizontal">
                                        <CheckBox Name="Group1" Content="Enable This Group"
                                                    Padding="4,0,0,0" VerticalContentAlignment="Center"
                                                    Style="{DynamicResource ToggleSwitch}" FontSize="14" />
                                    </StackPanel>
                                </GroupBox.Header>
                                <StackPanel Orientation="Vertical" DockPanel.Dock="Top"
                                            IsEnabled="{Binding ElementName=Group1, Path=IsChecked}">
                                    <Label Content="ComboBox 1" Margin="0" HorizontalAlignment="Left"
                                                VerticalAlignment="Top" />
                                    <ComboBox Name="ComboBox1" HorizontalAlignment="Stretch"
                                                VerticalAlignment="Top" />
                                    <Label Content="ComboxBox 2" Margin="0"
                                                HorizontalAlignment="Left" VerticalAlignment="Top" />
                                    <ComboBox Name="ComboBox2"
                                                HorizontalAlignment="Stretch"
                                                VerticalAlignment="Top" />
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Margin="0,5,0,0" VerticalAlignment="Center"
                                        HorizontalAlignment="Stretch">
                                <GroupBox.Header>
                                    <StackPanel Orientation="Horizontal">
                                        <CheckBox Name="Group2"
                                                    Content="Group 2" Padding="4,0,0,0"
                                                    VerticalContentAlignment="Center"
                                                    Style="{DynamicResource ToggleSwitch}" FontSize="14" />
                                    </StackPanel>
                                </GroupBox.Header>
                                <StackPanel Orientation="Vertical" DockPanel.Dock="Top"
                                            IsEnabled="{Binding ElementName=Group2, Path=IsChecked}">
                                    <Label Content="TextBox1" Margin="0" HorizontalAlignment="Left" VerticalAlignment="Top" />
                                    <TextBox Name="TextBox1" Margin="0,4,0,0" />
                                    <CheckBox Name="CheckBox1" Content="Example CheckBox " IsChecked="True" Margin="0,5,0,0" />
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Margin="0,5,0,0" Name="CredentialsGroup"
                                        IsEnabled="{Binding ElementName=Group1, Path=IsChecked}"
                                        VerticalAlignment="Center" HorizontalAlignment="Stretch">
                                <GroupBox.Header>
                                    <StackPanel Orientation="Horizontal"
                                                HorizontalAlignment="Center">
                                        <TextBlock TextAlignment="Center" Margin="0" FontSize="14">
                                                    <Run Text="Credentials (" Foreground="Black" />
                                                    <Run Text="REQUIRED" Foreground="Red" />
                                                    <Run Text=")" Foreground="Black" />
                                        </TextBlock>
                                    </StackPanel>
                                </GroupBox.Header>
                                <DockPanel Margin="0,4,0,0">
                                    <StackPanel Orientation="Vertical" DockPanel.Dock="Top">
                                        <Label Content="Domain" />
                                        <ComboBox Name="UserDomain" />
                                    </StackPanel>
                                    <StackPanel Orientation="Vertical" DockPanel.Dock="Top">
                                        <Label Content="Username" />
                                        <TextBox Name="UserName" Text="" />
                                    </StackPanel>
                                    <StackPanel Orientation="Vertical" DockPanel.Dock="Top">
                                        <Label Content="Password" />
                                        <PasswordBox Name="Password" />
                                    </StackPanel>
                                </DockPanel>
                            </GroupBox>
                            <Button Name="Execute" TabIndex="9" Content="Execute" IsDefault="True"
                                        HorizontalAlignment="Stretch" Height="30" FontSize="14"
                                        FontWeight="Normal" Margin="0,10,0,0" IsEnabled="True" />
                            <CheckBox Name="RebootRequired" Visibility="Collapsed" IsChecked="False" />
                        </StackPanel>
                        <GroupBox DockPanel.Dock="Right" HorizontalAlignment="Stretch"
                                    Margin="5,0,0,0">
                            <GroupBox.Header>
                                <StackPanel Orientation="Horizontal">
                                    <CheckBox Name="Group3" Content="Group 3"
                                                Padding="4,0,0,0" VerticalContentAlignment="Center"
                                                Style="{DynamicResource ToggleSwitch}" FontSize="14" />
                                </StackPanel>
                            </GroupBox.Header>
                            <DockPanel HorizontalAlignment="Stretch" Margin="0,0,8,0"
                                        IsEnabled="{Binding ElementName=Group3, Path=IsChecked}">
                                <Button Name="SetPath" DockPanel.Dock="Top" TabIndex="1"
                                            Content="Select Path" HorizontalAlignment="Left"
                                            Margin="0,10,0,0" VerticalAlignment="Top" Width="137"
                                            Height="30" FontSize="14" FontWeight="Normal" />
                                <TextBox Name="TextBox2" DockPanel.Dock="Top"
                                            HorizontalAlignment="Stretch" Margin="0,5,0,0"
                                            TextWrapping="Wrap" Text=" " VerticalAlignment="Top" 
                                            IsReadOnly="True" />
                                <ScrollViewer HorizontalScrollBarVisibility="Auto"
                                            VerticalScrollBarVisibility="Auto">
                                    <DataGrid
                                                Name="ExampleGrid"
                                                Margin="0,10,0,0"
                                                HorizontalAlignment="Stretch"
                                                VerticalAlignment="Top"
                                                AutoGenerateColumns="False"
                                                FrozenColumnCount="4"
                                                AlternationCount="2"
                                                GridLinesVisibility="None"
                                                DockPanel.Dock="Top"
                                                BorderBrush="{x:Null}"
                                                BorderThickness="0"
                                                Grid.Row="1"
                                                RowHeaderWidth="0"
                                                CanUserAddRows="False"
                                                SelectionMode="Single"
                                                IsReadOnly="True"
                                                ScrollViewer.CanContentScroll="True"
                                                ScrollViewer.VerticalScrollBarVisibility="Disabled"
                                                ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                                        <DataGrid.Columns>
                                            <DataGridTemplateColumn Header="ToggleSwitch">
                                                <DataGridTemplateColumn.CellTemplate>
                                                    <DataTemplate>
                                                        <CheckBox Name="CheckBox"
                                                                    IsChecked="{Binding Path=Checkbox, Mode=TwoWay, NotifyOnSourceUpdated=True, UpdateSourceTrigger=PropertyChanged}"
                                                                    Style="{DynamicResource ToggleSwitch}" IsEnabled="{Binding Path=EnableCheckbox, Mode=OneWay}"/>
                                                    </DataTemplate>
                                                </DataGridTemplateColumn.CellTemplate>
                                            </DataGridTemplateColumn>
                                            <DataGridTextColumn Header="Description" Width="Auto"
                                                        Binding="{Binding Path=Description, Mode=TwoWay, NotifyOnSourceUpdated=True}" />
                                            <DataGridTextColumn Header="Filename" Width="Auto"
                                                        Binding="{Binding Path=Filename, Mode=TwoWay, NotifyOnSourceUpdated=True}">
                                                <DataGridTextColumn.CellStyle>
                                                    <Style TargetType="DataGridCell">
                                                        <Style.Triggers>
                                                            <DataTrigger Binding="{Binding Path=RowIsValid}" Value="True">
                                                                <Setter Property="Foreground" Value="Black" />
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding Path=RowIsValid}" Value="False">
                                                                <Setter Property="Foreground" Value="Red" />
                                                            </DataTrigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </DataGridTextColumn.CellStyle>
                                            </DataGridTextColumn>
                                            <DataGridTextColumn Header="Extra Info" Width="Auto"
                                                        Binding="{Binding Path=ExtraInfo, Mode=TwoWay, NotifyOnSourceUpdated=True}" />
                                        </DataGrid.Columns>
                                    </DataGrid>
                                </ScrollViewer>
                            </DockPanel>
                        </GroupBox>
                    </DockPanel>
                    <GroupBox DockPanel.Dock="Top" Margin="10,10,10,0" Padding="8,0,8,8">
                        <RichTextBox Name="Output" FontSize="12" FontFamily="Consolas"
                                    Background="{x:Null}" BorderBrush="{x:Null}" IsReadOnly="True"
                                    BorderThickness="0" VerticalScrollBarVisibility="Auto" />
                    </GroupBox>
                </DockPanel>
            </Border>
    
            <!-- Status Area -->
            <Border Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Margin="10,0,10,0" BorderThickness="0" CornerRadius="8" HorizontalAlignment="Stretch">
                <StatusBar Name="StatusArea" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" Background="{x:Null}">
                    <StatusBarItem>
                        <ProgressBar Name="Progress" Value="0" />
                    </StatusBarItem>
                    <StatusBarItem>
                        <TextBlock Name="StatusText" Text="Ready." FontFamily="Verdana" />
                    </StatusBarItem>
                </StatusBar>
            </Border>

        </Grid>
    </Border>
</Window>
'@
            $ResourceXaML = @'
<!--

File: ControlTemplates.xaml
Modified Date: 2023-06-07
Author: Jeremy Crabtree <jcrabtree at nct911 org> / <jeremylc at gmail>
Purpose: Windows 11 styled WPF control templates
Copyright 2023 NCT 9-1-1

-->

<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
            xmlns:mc="http://schemas.openxmlformats.ouwpgrouprg/markup-compatibility/2006"
            xmlns:Themes="clr-namespace:Microsoft.Windows.Themes;assembly=PresentationFramework.Aero2"
            xmlns:dxe="http://schemas.devexpress.com/winfx/2008/xaml/editors"
            xmlns:dxg="http://schemas.devexpress.com/winfx/2008/xaml/grid"
            xmlns:col="clr-namespace:System.Collections;assembly=mscorlib"
            xmlns:sys="clr-namespace:System;assembly=mscorlib">

    <!-- The height of the TitleBar. Set here because this value is used in a few places in MainWindow.XaML -->
    <sys:Double x:Key="TitleBarHeight">32</sys:Double>

    <!-- A small styler to make the window border respond to being focused or unfocused -->
    <Style TargetType="Window">
        <Style.Triggers>
            <Trigger Property="IsActive" Value="False">
                <Setter Property="BorderBrush" Value="#FFAAAAAA" />
            </Trigger>
            <Trigger Property="IsActive" Value="True">
                <Setter Property="BorderBrush" Value="#FF005FB8" />
            </Trigger>
        </Style.Triggers>
    </Style>


    <!-- the static "crawling ants" that go around some controls when they have keyboard focus -->
    <Style x:Key="FocusVisual">
        <Setter Property="Control.Template">
            <Setter.Value>
                <ControlTemplate>
                    <Border BorderThickness="1" CornerRadius="4">
                        <Border.BorderBrush>
                            <DrawingBrush Viewport="0,0,8,8" ViewportUnits="Absolute"
                                        TileMode="Tile">
                                <DrawingBrush.Drawing>
                                    <DrawingGroup>
                                        <GeometryDrawing Brush="#FF005FB8">
                                            <GeometryDrawing.Geometry>
                                                <GeometryGroup>
                                                    <RectangleGeometry Rect="0,0,50,50" />
                                                    <RectangleGeometry Rect="50,50,50,50" />
                                                </GeometryGroup>
                                            </GeometryDrawing.Geometry>
                                        </GeometryDrawing>
                                    </DrawingGroup>
                                </DrawingBrush.Drawing>
                            </DrawingBrush>
                        </Border.BorderBrush>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- Similar to the above, but for different types of controls. -->
    <Style x:Key="OptionMarkFocusVisual">
        <Setter Property="Control.Template">
            <Setter.Value>
                <ControlTemplate>
                    <Rectangle Margin="14,0,0,0" SnapsToDevicePixels="true"
                                Stroke="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}"
                                StrokeThickness="1" StrokeDashArray="1 2" />
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- This is the sliding toggle switch. there's not a native WPF equivalent, so this is a re-styled checkbox -->
    <Style x:Key="ToggleSwitch" TargetType="{x:Type CheckBox}">
        <Setter Property="Height" Value="20" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type CheckBox}">
                    <Grid Height="{TemplateBinding Height}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <Viewbox Grid.Column="0" Stretch="Uniform" Height="{TemplateBinding Height}">
                            <Border x:Name="bk" Background="#FFEDEDED" BorderBrush="#FF858585"
                                        BorderThickness="1" CornerRadius="10" MinWidth="35" Height="20">
                                <Ellipse x:Name="ep" Fill="#FF5A5A5A" HorizontalAlignment="Left"
                                            Margin="2" Width="14" Height="14" />
                            </Border>
                        </Viewbox>
                        <ContentPresenter x:Name="contentPresenter" Grid.Column="1"
                                    Focusable="False"
                                    HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                    Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"
                                    SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"
                                    VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger  Property="IsChecked" Value="true">
                            <Setter TargetName="ep" Property="HorizontalAlignment" Value="Right" />
                        </Trigger>

                        <MultiTrigger>
                            <MultiTrigger.Conditions>
                                <Condition Property="IsChecked" Value="true" />
                                <Condition Property="IsEnabled" Value="true" />
                            </MultiTrigger.Conditions>
                            <Setter TargetName="ep" Property="HorizontalAlignment" Value="Right" />
                            <Setter Property="Background" TargetName="bk" Value="#FF005FB8" />
                            <Setter Property="BorderBrush" TargetName="bk" Value="#FF005FB8" />
                            <Setter Property="Fill" TargetName="ep" Value="#FFFFFFFF" />
                        </MultiTrigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>


    <!-- combobox -->
    <SolidColorBrush x:Key="ComboBox.Static.Background" Color="White" />
    <SolidColorBrush x:Key="ComboBox.Static.Foreground" Color="#FF000000" />
    <SolidColorBrush x:Key="ComboBox.Static.Border" Color="#FFBDBDBD" />
    <SolidColorBrush x:Key="ComboBox.Static.Editable.Background" Color="#FFF7F7F7" />
    <SolidColorBrush x:Key="ComboBox.Static.Editable.Border" Color="#FFABADB3" />
    <SolidColorBrush x:Key="ComboBox.Static.Editable.Button.Background" Color="Transparent" />
    <SolidColorBrush x:Key="ComboBox.Static.Editable.Button.Border" Color="Transparent" />
    <SolidColorBrush x:Key="ComboBox.MouseOver.Glyph" Color="#FF005FB8" />
    <SolidColorBrush x:Key="ComboBox.MouseOver.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="ComboBox.MouseOver.Border" Color="#FF005FB8" />
    <SolidColorBrush x:Key="ComboBox.MouseOver.Editable.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="ComboBox.MouseOver.Editable.Border" Color="#FF005FB8" />
    <LinearGradientBrush x:Key="ComboBox.MouseOver.Editable.Button.Background" EndPoint="0,1"
                StartPoint="0,0">
        <GradientStop Color="#FFEBF4FC" Offset="0.0" />
        <GradientStop Color="#FFDCECFC" Offset="1.0" />
    </LinearGradientBrush>
    <SolidColorBrush x:Key="ComboBox.MouseOver.Editable.Button.Border" Color="#FF007ACC" />
    <SolidColorBrush x:Key="ComboBox.Pressed.Glyph" Color="#FF000000" />
    <SolidColorBrush x:Key="ComboBox.Pressed.Background" Color="#FFf2f2f2" />
    <SolidColorBrush x:Key="ComboBox.Pressed.Border" Color="#FF666666" />
    <SolidColorBrush x:Key="ComboBox.Pressed.Editable.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="ComboBox.Pressed.Editable.Border" Color="#FF569DE5" />
    <LinearGradientBrush x:Key="ComboBox.Pressed.Editable.Button.Background" EndPoint="0,1"
                StartPoint="0,0">
        <GradientStop Color="#FFDAEBFC" Offset="0.0" />
        <GradientStop Color="#FFC4E0FC" Offset="1.0" />
    </LinearGradientBrush>
    <SolidColorBrush x:Key="ComboBox.Pressed.Editable.Button.Border" Color="#FF569DE5" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Glyph" Color="#FFBFBFBF" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Border" Color="#FFD9D9D9" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Editable.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Editable.Border" Color="#FFBFBFBF" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Editable.Button.Background" Color="Transparent" />
    <SolidColorBrush x:Key="ComboBox.Disabled.Editable.Button.Border" Color="Transparent" />
    <SolidColorBrush x:Key="ComboBox.Static.Glyph" Color="#FF797979" />
    <Style x:Key="ComboBoxToggleButton" TargetType="{x:Type ToggleButton}">
        <Setter Property="OverridesDefaultStyle" Value="true" />
        <Setter Property="IsTabStop" Value="false" />
        <Setter Property="Focusable" Value="false" />
        <Setter Property="ClickMode" Value="Press" />
        <Setter Property="Background" Value="White" />
        <Setter Property="BorderBrush" Value="#FFBDBDBD" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ToggleButton}">
                    <Border x:Name="templateRoot" CornerRadius="4" SnapsToDevicePixels="true"
                                Background="{TemplateBinding Background}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                BorderBrush="{StaticResource ComboBox.Static.Border}">
                        <Border x:Name="splitBorder" CornerRadius="4"
                                    Width="{DynamicResource {x:Static SystemParameters.VerticalScrollBarWidthKey}}"
                                    SnapsToDevicePixels="true" Margin="0,0,8,0" HorizontalAlignment="Right">
                            <Viewbox Stretch="Uniform" Margin="4,0,4,0">
                                <Path x:Name="arrow" VerticalAlignment="Center" Margin="0"
                                            HorizontalAlignment="Center"
                                            Fill="{TemplateBinding BorderBrush}"
                                            Data="F1 M 0.13229166,0.68952498 2.2489584,2.8061114 4.365625,0.68952498 V 0.31938024 L 2.2489584,2.436047 0.13229166,0.31938024 Z"
                                            StrokeThickness="0"
                                            Stroke="{StaticResource ComboBox.Static.Glyph}" />
                            </Viewbox>
                        </Border>
                    </Border>
                    <ControlTemplate.Triggers>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="true" />
                                <Condition
                                            Binding="{Binding IsMouseOver, RelativeSource={RelativeSource Self}}"
                                            Value="false" />
                                <Condition
                                            Binding="{Binding IsPressed, RelativeSource={RelativeSource Self}}"
                                            Value="false" />
                                <Condition
                                            Binding="{Binding IsEnabled, RelativeSource={RelativeSource Self}}"
                                            Value="true" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Static.Editable.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Static.Editable.Border}" />
                            <Setter Property="Background" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Static.Editable.Button.Background}" />
                            <Setter Property="BorderBrush" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Static.Editable.Button.Border}" />
                        </MultiDataTrigger>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="Fill" TargetName="arrow"
                                        Value="{StaticResource ComboBox.MouseOver.Glyph}" />
                        </Trigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsMouseOver, RelativeSource={RelativeSource Self}}"
                                            Value="true" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="false" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.MouseOver.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.MouseOver.Border}" />
                        </MultiDataTrigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsMouseOver, RelativeSource={RelativeSource Self}}"
                                            Value="true" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="true" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.MouseOver.Editable.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.MouseOver.Editable.Border}" />
                            <Setter Property="Background" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.MouseOver.Editable.Button.Background}" />
                            <Setter Property="BorderBrush" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.MouseOver.Editable.Button.Border}" />
                        </MultiDataTrigger>
                        <Trigger Property="IsPressed" Value="true">
                            <Setter Property="Fill" TargetName="arrow"
                                        Value="{StaticResource ComboBox.Pressed.Glyph}" />
                        </Trigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsPressed, RelativeSource={RelativeSource Self}}"
                                            Value="true" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="false" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Pressed.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Pressed.Border}" />
                        </MultiDataTrigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsPressed, RelativeSource={RelativeSource Self}}"
                                            Value="true" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="true" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Pressed.Editable.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Pressed.Editable.Border}" />
                            <Setter Property="Background" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Pressed.Editable.Button.Background}" />
                            <Setter Property="BorderBrush" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Pressed.Editable.Button.Border}" />
                        </MultiDataTrigger>
                        <Trigger Property="IsEnabled" Value="false">
                            <Setter Property="Fill" TargetName="arrow"
                                        Value="{StaticResource ComboBox.Disabled.Glyph}" />
                        </Trigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsEnabled, RelativeSource={RelativeSource Self}}"
                                            Value="false" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="false" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Disabled.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Disabled.Border}" />
                        </MultiDataTrigger>
                        <MultiDataTrigger>
                            <MultiDataTrigger.Conditions>
                                <Condition
                                            Binding="{Binding IsEnabled, RelativeSource={RelativeSource Self}}"
                                            Value="false" />
                                <Condition
                                            Binding="{Binding IsEditable, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                            Value="true" />
                            </MultiDataTrigger.Conditions>
                            <Setter Property="Background" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Disabled.Editable.Background}" />
                            <Setter Property="BorderBrush" TargetName="templateRoot"
                                        Value="{StaticResource ComboBox.Disabled.Editable.Border}" />
                            <Setter Property="Background" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Disabled.Editable.Button.Background}" />
                            <Setter Property="BorderBrush" TargetName="splitBorder"
                                        Value="{StaticResource ComboBox.Disabled.Editable.Button.Border}" />
                        </MultiDataTrigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <ControlTemplate x:Key="ComboBoxTemplate" TargetType="{x:Type ComboBox}">
        <Grid x:Name="templateRoot" SnapsToDevicePixels="true">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="32" />
            </Grid.ColumnDefinitions>
            <Popup x:Name="PART_Popup" AllowsTransparency="true" Grid.ColumnSpan="2"
                        IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                        Margin="1"
                        PopupAnimation="Slide"
                        Placement="Bottom">
                <Border x:Name="dropDownBorder" CornerRadius="4"
                            Width="{Binding ActualWidth, ElementName=templateRoot}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            Background="{TemplateBinding Background}" Padding="0" Margin="0">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="4" Opacity="0.3" ShadowDepth="2" Direction="290" Color="#FFC7C7C7" />
                    </Border.Effect>
                    <ScrollViewer x:Name="DropDownScrollViewer"
                                Width="{Binding ActualWidth, ElementName=toggleButton}" Margin="0" Padding="2">
                        <StackPanel IsItemsHost="True"
                                    KeyboardNavigation.DirectionalNavigation="Contained" MaxHeight="200" Margin="2,0,2,0"/>
                    </ScrollViewer>
                </Border>
            </Popup>
            <ToggleButton x:Name="toggleButton" BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        Background="{TemplateBinding Background}" Grid.ColumnSpan="2"
                        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                        Style="{StaticResource ComboBoxToggleButton}" />
            <ContentPresenter x:Name="contentPresenter"
                        ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                        ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                        Content="{TemplateBinding SelectionBoxItem}"
                        ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                        HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                        IsHitTestVisible="false" Margin="{TemplateBinding Padding}"
                        SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"
                        VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
        </Grid>
        <ControlTemplate.Triggers>
            <Trigger Property="HasItems" Value="false">
                <Setter Property="Height" TargetName="dropDownBorder" Value="95" />
            </Trigger>
            <MultiTrigger>
                <MultiTrigger.Conditions>
                    <Condition Property="IsGrouping" Value="true" />
                    <Condition Property="VirtualizingPanel.IsVirtualizingWhenGrouping" Value="false" />
                </MultiTrigger.Conditions>
                <Setter Property="ScrollViewer.CanContentScroll" Value="false" />
            </MultiTrigger>
        </ControlTemplate.Triggers>
    </ControlTemplate>
    <SolidColorBrush x:Key="TextBox.Static.Background" Color="#FFFFFFFF" />
    <Style TargetType="{x:Type ComboBox}">
        <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}" />
        <Setter Property="Background" Value="{StaticResource ComboBox.Static.Background}" />
        <Setter Property="BorderBrush" Value="{StaticResource ComboBox.Static.Border}" />
        <Setter Property="Foreground"
                    Value="{DynamicResource {x:Static SystemColors.WindowTextBrushKey}}" />
        <Setter Property="BorderThickness" Value="1,1,1,2" />
        <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto" />
        <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto" />
        <Setter Property="Padding" Value="8,4,4,8" />
        <Setter Property="FontFamily" Value="Segoe UI" />
        <Setter Property="FontSize" Value="12" />
        <Setter Property="ScrollViewer.CanContentScroll" Value="true" />
        <Setter Property="ScrollViewer.PanningMode" Value="Both" />
        <Setter Property="Stylus.IsFlicksEnabled" Value="False" />
        <Setter Property="Template" Value="{StaticResource ComboBoxTemplate}" />
        <Setter Property="ItemContainerStyle">
            <Setter.Value>
                <Style TargetType="ComboBoxItem">
                    <Setter Property="BorderThickness" Value="2,0,0,0" />
                    <Setter Property="Margin" Value="2" />
                    <Setter Property="Padding" Value="2,0,0,0" />
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ComboBoxItem">
                                <Border Name="Back" BorderBrush="{TemplateBinding BorderBrush}"
                                            BorderThickness="{TemplateBinding BorderThickness}"
                                            Background="{TemplateBinding Background}" Margin="2,0,0,0">
                                    <ContentPresenter ContentSource="{Binding Source}"
                                                VerticalAlignment="Center" HorizontalAlignment="Left"
                                                Margin="4,2,4,2" />
                                </Border>
                                <ControlTemplate.Triggers>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="False" />
                                            <Condition Property="IsMouseOver" Value="True" />
                                            <Condition Property="IsKeyboardFocused" Value="False" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="Background" Value="#FFCCCCCC" />
                                    </MultiTrigger>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="True" />
                                            <Condition Property="IsMouseOver" Value="False" />
                                            <Condition Property="IsKeyboardFocused" Value="True" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="BorderBrush" Value="#FF005FB8" />
                                    </MultiTrigger>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="True" />
                                            <Condition Property="IsMouseOver" Value="True" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="BorderBrush" Value="#FF005FB8" />
                                        <Setter Property="Background" Value="#FFCCCCCC" />
                                    </MultiTrigger>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="True" />
                                            <Condition Property="IsMouseOver" Value="False" />
                                            <Condition Property="IsKeyboardFocused" Value="False" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="Background" Value="White" />
                                        <Setter Property="BorderBrush" Value="#FF005FB8" />
                                    </MultiTrigger>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="False" />
                                            <Condition Property="IsMouseOver" Value="False" />
                                            <Condition Property="IsKeyboardFocused" Value="True" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="Background" Value="#FFCCCCCC" />
                                    </MultiTrigger>
                                    <MultiTrigger>
                                        <MultiTrigger.Conditions>
                                            <Condition Property="IsSelected" Value="False" />
                                            <Condition Property="IsMouseOver" Value="True" />
                                            <Condition Property="IsKeyboardFocused" Value="True" />
                                        </MultiTrigger.Conditions>
                                        <Setter Property="Background" Value="#FFCCCCCC" />
                                    </MultiTrigger>

                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                    <Setter Property="Control.ToolTip" Value="{Binding Description}" />
                </Style>
            </Setter.Value>
        </Setter>
    </Style>


    <!-- Checkbox -->
    <SolidColorBrush x:Key="OptionMark.Static.Background" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="OptionMark.Static.Border" Color="#FFB0B0B0" />
    <SolidColorBrush x:Key="OptionMark.MouseOver.Background" Color="#FFF3F9FF" />
    <SolidColorBrush x:Key="OptionMark.MouseOver.Border" Color="#FF5593FF" />
    <SolidColorBrush x:Key="OptionMark.MouseOver.Glyph" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="OptionMark.Disabled.Background" Color="#FFE6E6E6" />
    <SolidColorBrush x:Key="OptionMark.Disabled.Border" Color="#FFBCBCBC" />
    <SolidColorBrush x:Key="OptionMark.Disabled.Glyph" Color="#FF707070" />
    <SolidColorBrush x:Key="OptionMark.Pressed.Background" Color="#FFD9ECFF" />
    <SolidColorBrush x:Key="OptionMark.Pressed.Border" Color="#FF3C77DD" />
    <SolidColorBrush x:Key="OptionMark.Pressed.Glyph" Color="#FF212121" />
    <SolidColorBrush x:Key="OptionMark.Static.Glyph" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="OptionMark.IsChecked.Background" Color="#FF267CCD" />
    <SolidColorBrush x:Key="OptionMark.IsChecked.Border" Color="#FF2677CD" />
    <Style TargetType="{x:Type CheckBox}">
        <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}" />
        <Setter Property="Background" Value="{StaticResource OptionMark.Static.Background}" />
        <Setter Property="BorderBrush" Value="{StaticResource OptionMark.Static.Border}" />
        <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Height" Value="16" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type CheckBox}">
                    <Grid x:Name="templateRoot"
                          Height="{TemplateBinding Height}"
                          Width="{TemplateBinding Width}"
                          Background="{TemplateBinding Background}"
                          HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                          SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}" >
                        <DockPanel Margin="{TemplateBinding Padding}">
                            <Viewbox DockPanel.Dock="Left" Grid.Column="0" Width="{TemplateBinding Height}" Height="{TemplateBinding Height}" Stretch="Uniform">
                                <Border x:Name="checkBoxBorder" CornerRadius="2"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}"
                                        BorderThickness="{TemplateBinding BorderThickness}"
                                        HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                        Margin="0"
                                        VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Grid.Column="0">
                                    <Grid x:Name="markGrid" Width="16" Height="16">
                                        <Viewbox Width="11  " Height="16" Stretch="Uniform">
                                            <Path x:Name="optionMark"
                                                    Data="F1 M 2.1912781,0.39716894 0.84717119,1.6606607 0.15010523,1.0066948 0.14137505,0.70562077 0.84717119,1.3595866 2.1825479,0.0960949 Z"
                                                    Fill="{TemplateBinding Background}" Opacity="0"
                                                    Stretch="None" />
                                        </Viewbox>
                                        <Rectangle x:Name="indeterminateMark"
                                                Fill="{StaticResource OptionMark.Static.Glyph}" Margin="2"
                                                Opacity="0" />
                                    </Grid>
                                </Border>
                            </Viewbox>
                            <ContentPresenter x:Name="contentPresenter" DockPanel.Dock="Left" Focusable="False" RecognizesAccessKey="True" HorizontalAlignment="Left" Margin="4,0,0,0"/>
                        </DockPanel>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="HasContent" Value="true">
                            <Setter Property="FocusVisualStyle" Value="{StaticResource OptionMarkFocusVisual}" />
                            <Setter Property="Padding" Value="0" />
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="Background"  TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.MouseOver.Background}" />
                            <Setter Property="BorderBrush" TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.MouseOver.Border}" />
                            <Setter Property="Fill"        TargetName="optionMark"        Value="{StaticResource OptionMark.MouseOver.Glyph}" />
                            <Setter Property="Fill"        TargetName="indeterminateMark" Value="{StaticResource OptionMark.MouseOver.Glyph}" />
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="false">
                            <Setter Property="Background"  TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.Disabled.Background}" />
                            <Setter Property="BorderBrush" TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.Disabled.Border}" />
                            <Setter Property="Fill"        TargetName="optionMark"        Value="{StaticResource OptionMark.Disabled.Glyph}" />
                            <Setter Property="Fill"        TargetName="indeterminateMark" Value="{StaticResource OptionMark.Disabled.Glyph}" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="true">
                            <Setter Property="Background"  TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.Pressed.Background}" />
                            <Setter Property="BorderBrush" TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.Pressed.Border}" />
                            <Setter Property="Fill"        TargetName="optionMark"        Value="{StaticResource OptionMark.Pressed.Glyph}" />
                            <Setter Property="Fill"        TargetName="indeterminateMark" Value="{StaticResource OptionMark.Pressed.Glyph}" />
                        </Trigger>
                        <MultiTrigger>
                            <MultiTrigger.Conditions>
                                <Condition Property="IsChecked" Value="true" />
                                <Condition Property="IsEnabled" Value="true" />
                            </MultiTrigger.Conditions>
                            <Setter Property="Background"  TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.IsChecked.Background}" />
                            <Setter Property="Background"  TargetName="markGrid"          Value="{StaticResource OptionMark.IsChecked.Background}" />
                            <Setter Property="BorderBrush" TargetName="checkBoxBorder"    Value="{StaticResource OptionMark.IsChecked.Border}" />
                            <Setter Property="Opacity"     TargetName="optionMark"        Value="1" />
                            <Setter Property="Opacity"     TargetName="indeterminateMark" Value="0" />
                        </MultiTrigger>
                        <MultiTrigger>
                            <MultiTrigger.Conditions>
                                <Condition Property="IsChecked" Value="true" />
                                <Condition Property="IsEnabled" Value="false" />
                            </MultiTrigger.Conditions>
                            <Setter Property="Opacity"     TargetName="optionMark"        Value="1" />
                            <Setter Property="Opacity"     TargetName="indeterminateMark" Value="0" />
                        </MultiTrigger>
                        <Trigger Property="IsChecked" Value="{x:Null}">
                            <Setter Property="Opacity" TargetName="optionMark" Value="0" />
                            <Setter Property="Opacity" TargetName="indeterminateMark" Value="1" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- Progress bar -->
    <SolidColorBrush x:Key="PressedBrush" Color="#FFC2C2C2" />
    <SolidColorBrush x:Key="SolidBorderBrush" Color="#FFC2C2C2" />
    <SolidColorBrush x:Key="DarkBrush" Color="#FF277CD4" />
    <SolidColorBrush x:Key="NormalBorderBrush" Color="#FF277CD4" />
    <Style TargetType="{x:Type ProgressBar}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ProgressBar}">
                    <Grid MinHeight="8" MinWidth="200">
                        <Border Name="PART_Track"
                                    Background="{StaticResource SolidBorderBrush}"
                                    BorderBrush="Transparent" BorderThickness="1" CornerRadius="1" Height="3"/>
                        <Border Name="PART_Indicator" CornerRadius="1" Height="3"
                                    Background="{StaticResource NormalBorderBrush}"
                                    BorderBrush="{StaticResource NormalBorderBrush}" BorderThickness="1"
                                    HorizontalAlignment="Left" Margin="-1,0,0,0" >
                            <Border Background="{StaticResource NormalBorderBrush}" Height="2" Margin="0,-1,0,-1"/>
                        </Border>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- generic button -->
    <SolidColorBrush x:Key="Button.Static.Background" Color="#FFFBFBFB" />
    <SolidColorBrush x:Key="Button.Static.Border" Color="#FFCCCCCC" />
    <SolidColorBrush x:Key="Button.MouseOver.Background" Color="#FF005FB8" />
    <SolidColorBrush x:Key="Button.MouseOver.Foreground" Color="#FFFFFFFF" />
    <SolidColorBrush x:Key="Button.MouseOver.Border" Color="#FF005FB8" />
    <SolidColorBrush x:Key="Button.Pressed.Background" Color="#FF606060" />
    <SolidColorBrush x:Key="Button.Pressed.Border" Color="#FF606060" />
    <SolidColorBrush x:Key="Button.Disabled.Background" Color="#FFF0F0F0" />
    <SolidColorBrush x:Key="Button.Disabled.Border" Color="#FFADB2B5" />
    <SolidColorBrush x:Key="Button.Disabled.Foreground" Color="#FF838383" />
    <SolidColorBrush x:Key="Button.Default.Foreground" Color="White" />
    <SolidColorBrush x:Key="Button.Default.Background" Color="#FF005FB8" />
    <SolidColorBrush x:Key="Button.Default.Border" Color="#FF005FB8" />
    <Style TargetType="{x:Type Button}">
        <Setter Property="FocusVisualStyle" Value="{StaticResource FocusVisual}" />
        <Setter Property="BorderBrush" Value="{StaticResource Button.Static.Border}" />
        <Setter Property="Background" Value="{StaticResource Button.Static.Background}" />
        <Setter Property="Foreground"
                    Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
        <Setter Property="BorderThickness" Value="1,1,1,2" />
        <Setter Property="HorizontalContentAlignment" Value="Center" />
        <Setter Property="VerticalContentAlignment" Value="Center" />
        <Setter Property="Padding" Value="8,4,8,4" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border BorderThickness="0" Background="{TemplateBinding Background}" CornerRadius="4">
                        <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"
                                    Background="{TemplateBinding Background}" SnapsToDevicePixels="true"
                                    CornerRadius="4" Padding="0" Margin="0">
                            <ContentPresenter x:Name="contentPresenter" Focusable="False"
                                    HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                    Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"
                                    SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"
                                    VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                        </Border>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="IsDefault" Value="true">
                <Setter Property="BorderBrush" Value="{StaticResource Button.Default.Border}" />
                <Setter Property="Background" Value="{StaticResource Button.Default.Background}" />
                <Setter Property="Foreground" Value="{StaticResource Button.Default.Foreground}" />
            </Trigger>
            <Trigger Property="IsMouseOver" Value="true">
                <Setter Property="Background" Value="{StaticResource Button.MouseOver.Background}" />
                <Setter Property="Foreground" Value="{StaticResource Button.MouseOver.Foreground}" />
                <Setter Property="BorderBrush" Value="{StaticResource Button.MouseOver.Border}" />
            </Trigger>
            <Trigger Property="IsPressed" Value="true">
                <Setter Property="Background" Value="{StaticResource Button.Pressed.Background}" />
                <Setter Property="BorderBrush" Value="{StaticResource Button.Pressed.Border}" />
            </Trigger>
            <Trigger Property="IsEnabled" Value="false">
                <Setter Property="Background" Value="{StaticResource Button.Disabled.Background}" />
                <Setter Property="BorderBrush" Value="{StaticResource Button.Disabled.Background}" />
                <Setter Property="TextElement.Foreground"
                            Value="{StaticResource Button.Disabled.Foreground}" />
            </Trigger>

        </Style.Triggers>
    </Style>

    <!-- GroupBox -->
    <BorderGapMaskConverter x:Key="BorderGapMaskConverter" />
    <Style TargetType="{x:Type GroupBox}">
        <Setter Property="BorderBrush" Value="#FFC8C8C8" />
        <Setter Property="Background" Value="#FFFFFFFF" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="5" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type GroupBox}">
                    <Grid SnapsToDevicePixels="true">
                        <Border BorderBrush="{TemplateBinding BorderBrush}" CornerRadius="4"
                                    BorderThickness="{TemplateBinding BorderThickness}" Grid.ColumnSpan="4"
                                    Grid.Row="1" Grid.RowSpan="3" Background="White">
                            <DockPanel>
                                <ContentPresenter DockPanel.Dock="Top"
                                            Margin="{TemplateBinding Padding}" ContentSource="Header"
                                            RecognizesAccessKey="True"
                                            SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"
                                            HorizontalAlignment="Stretch" VerticalAlignment="Top" />
                                <ContentPresenter DockPanel.Dock="Top"
                                            Margin="{TemplateBinding Padding}"
                                            SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" />
                            </DockPanel>
                        </Border>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>


    <!-- DataGrid related styles -->
    <Style TargetType="DataGridColumnHeader">
        <Setter Property="HorizontalContentAlignment" Value="Center" />
        <Setter Property="Background" Value="White" />
        <Setter Property="BorderThickness" Value="0,0,0,2" />
        <Setter Property="BorderBrush" Value="#FF005FB8" />
        <Setter Property="Padding" Value="2,0,2,2" />
    </Style>
    <Style TargetType="DataGridCell">
        <Setter Property="BorderThickness" Value="0,0,0,0" />
        <Setter Property="Margin" Value="2" />
        <Setter Property="Padding" Value="4" />
    </Style>
    <Style TargetType="{x:Type DataGridRow}">
        <Style.Triggers>
            <Trigger Property="AlternationIndex" Value="0">
                <Setter Property="Foreground" Value="Black" />
                <Setter Property="Background" Value="White" />
                <Setter Property="Padding" Value="10" />
            </Trigger>
            <Trigger Property="AlternationIndex" Value="1">
                <Setter Property="Foreground" Value="Black" />
                <Setter Property="Background" Value="Gainsboro" />
            </Trigger>
            <DataTrigger Binding="{Binding Path=Selectable}" Value="False">
                <DataTrigger.Setters>
                    <Setter Property="Background" Value="SkyBlue" />
                </DataTrigger.Setters>
            </DataTrigger>
        </Style.Triggers>
    </Style>

    <!-- TextBox -->
    <SolidColorBrush x:Key="TextBox.Static.Border" Color="#7F7A7A7A" />
    <SolidColorBrush x:Key="TextBox.MouseOver.Border" Color="#FF005FB8" />
    <SolidColorBrush x:Key="TextBox.Focus.Border" Color="#FF005FB8" />
    <Style TargetType="{x:Type TextBox}">
        <Setter Property="Background"
                    Value="{DynamicResource {x:Static SystemColors.WindowBrushKey}}" />
        <Setter Property="BorderBrush" Value="{StaticResource TextBox.Static.Border}" />
        <Setter Property="Foreground"
                    Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
        <Setter Property="Padding" Value="8,4,4,8" />
        <Setter Property="BorderThickness" Value="1,1,1,2" />
        <Setter Property="FontFamily" Value="Segoe UI" />
        <Setter Property="KeyboardNavigation.TabNavigation" Value="None" />
        <Setter Property="HorizontalContentAlignment" Value="Left" />
        <Setter Property="VerticalContentAlignment" Value="Center" />
        <Setter Property="FocusVisualStyle" Value="{x:Null}" />
        <Setter Property="AllowDrop" Value="true" />
        <Setter Property="ScrollViewer.PanningMode" Value="VerticalFirst" />
        <Setter Property="Stylus.IsFlicksEnabled" Value="False" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type TextBox}">
                    <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Background="{TemplateBinding Background}" SnapsToDevicePixels="True"
                                CornerRadius="4">
                        <ScrollViewer x:Name="PART_ContentHost" Focusable="false"
                                    HorizontalScrollBarVisibility="Hidden"
                                    VerticalScrollBarVisibility="Hidden" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsEnabled" Value="false">
                            <Setter Property="Opacity" TargetName="border" Value="0.56" />
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="true">
                            <Setter Property="Opacity" TargetName="border" Value="1" />
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="BorderBrush" TargetName="border"
                                        Value="{StaticResource TextBox.MouseOver.Border}" />
                        </Trigger>
                        <Trigger Property="IsKeyboardFocused" Value="true">
                            <Setter Property="BorderBrush" TargetName="border"
                                        Value="{StaticResource TextBox.Focus.Border}" />
                            <Setter Property="BorderThickness" TargetName="border" Value="1,1,1,2" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <MultiTrigger>
                <MultiTrigger.Conditions>
                    <Condition Property="IsInactiveSelectionHighlightEnabled" Value="true" />
                    <Condition Property="IsSelectionActive" Value="false" />
                </MultiTrigger.Conditions>
                <Setter Property="SelectionBrush"
                            Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightBrushKey}}" />
            </MultiTrigger>
        </Style.Triggers>
    </Style>

    <!-- PasswordBox -->
    <SolidColorBrush x:Key="TextBox.Static.Border2" Color="#FF7A7A7A" />
    <SolidColorBrush x:Key="TextBox.MouseOver.Border2" Color="#FF005FB8" />
    <SolidColorBrush x:Key="TextBox.Focus.Border2" Color="#FF005FB8" />
    <Style TargetType="{x:Type PasswordBox}">
        <Setter Property="PasswordChar" Value="●" />
        <Setter Property="Background"
                    Value="{DynamicResource {x:Static SystemColors.WindowBrushKey}}" />
        <Setter Property="BorderBrush" Value="{StaticResource TextBox.Static.Border}" />
        <Setter Property="Foreground"
                    Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
        <Setter Property="Padding" Value="8,4,4,8" />
        <Setter Property="BorderThickness" Value="1,1,1,2" />
        <Setter Property="KeyboardNavigation.TabNavigation" Value="None" />
        <Setter Property="HorizontalContentAlignment" Value="Left" />
        <Setter Property="FocusVisualStyle" Value="{x:Null}" />
        <Setter Property="AllowDrop" Value="true" />
        <Setter Property="ScrollViewer.PanningMode" Value="VerticalFirst" />
        <Setter Property="Stylus.IsFlicksEnabled" Value="False" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type PasswordBox}">
                    <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Background="{TemplateBinding Background}" SnapsToDevicePixels="True"
                                CornerRadius="4">
                        <ScrollViewer x:Name="PART_ContentHost" Focusable="false"
                                    HorizontalScrollBarVisibility="Hidden"
                                    VerticalScrollBarVisibility="Hidden" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsEnabled" Value="false">
                            <Setter Property="Opacity" TargetName="border" Value="0.56" />
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="BorderBrush" TargetName="border"
                                        Value="{StaticResource TextBox.MouseOver.Border}" />
                        </Trigger>
                        <Trigger Property="IsKeyboardFocused" Value="true">
                            <Setter Property="BorderBrush" TargetName="border"
                                        Value="{StaticResource TextBox.Focus.Border}" />
                            <Setter Property="BorderThickness" TargetName="border" Value="1,1,1,2" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <MultiTrigger>
                <MultiTrigger.Conditions>
                    <Condition Property="IsInactiveSelectionHighlightEnabled" Value="true" />
                    <Condition Property="IsSelectionActive" Value="false" />
                </MultiTrigger.Conditions>
                <Setter Property="SelectionBrush"
                            Value="{DynamicResource {x:Static SystemColors.InactiveSelectionHighlightBrushKey}}" />
            </MultiTrigger>
        </Style.Triggers>
    </Style>

    <!-- TabPanel, TabItem, TabControl -->
    <SolidColorBrush x:Key="UWPTab.SelectedColor" Color="#FFF0F0F0" />
    <LinearGradientBrush x:Key="UWPTab.SelectedColorHighlight" StartPoint="1,1" EndPoint="1,0">
        <GradientStop Color="#FFF0F0F0" Offset="0" />
        <GradientStop Color="White" Offset="1" />
    </LinearGradientBrush>
    <SolidColorBrush x:Key="UWPTab.SelectedTextColor" Color="Black" />
    <SolidColorBrush x:Key="UWPTab.UnSelectedColor" Color="#FFF0F0F0" />
    <SolidColorBrush x:Key="UWPTab.UnSelectedTextColor" Color="#FF9A9A9A" />
    <SolidColorBrush x:Key="TabItem.Selected.Background" Color="#FFFFFF" />
    <SolidColorBrush x:Key="TabItem.Selected.Border" Color="#FF005FB8" />
    <Style TargetType="{x:Type TabControl}">
        <Setter Property="Padding" Value="0" />
        <Setter Property="Margin" Value="0" />
        <Setter Property="HorizontalContentAlignment" Value="Center" />
        <Setter Property="VerticalContentAlignment" Value="Center" />
        <Setter Property="Background" Value="{StaticResource UWPTab.UnSelectedColor}" />
        <Setter Property="BorderBrush" Value="{StaticResource TabItem.Selected.Border}" />
        <Setter Property="BorderThickness" Value="0,0,0,2" />
        <Setter Property="Foreground"
                    Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type TabControl}">
                    <Grid x:Name="templateRoot" ClipToBounds="true" SnapsToDevicePixels="true"
                                KeyboardNavigation.TabNavigation="Local"
                                Background="{TemplateBinding Background}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition x:Name="ColumnDefinition0" />
                            <ColumnDefinition x:Name="ColumnDefinition1" Width="0" />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition x:Name="RowDefinition0" Height="Auto" />
                            <RowDefinition x:Name="RowDefinition1" Height="*" />
                        </Grid.RowDefinitions>
                        <UniformGrid x:Name="headerPanel" Background="{TemplateBinding Background}"
                                    Grid.Column="0" IsItemsHost="true" Margin="4,4,4,0" Grid.Row="0"
                                    Rows="1" KeyboardNavigation.TabIndex="1" Panel.ZIndex="1"
                                    ClipToBounds="False" />
                        <Border x:Name="contentPanel"
                                    BorderBrush="{DynamicResource TabItem.Selected.Border}"
                                    Background="{TemplateBinding Background}" BorderThickness="0"
                                    Grid.Column="0" KeyboardNavigation.DirectionalNavigation="Contained"
                                    Grid.Row="1" KeyboardNavigation.TabIndex="2"
                                    KeyboardNavigation.TabNavigation="Local">
                            <ContentPresenter x:Name="PART_SelectedContentHost"
                                        ContentSource="SelectedContent" Margin="{TemplateBinding Padding}"
                                        SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" />
                        </Border>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="{x:Type TabPanel}">
        <Setter Property="HorizontalAlignment" Value="Left" />
    </Style>
    <Style TargetType="TabItem">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="TabItem">
                    <Grid Name="Panel" Margin="0">
                        <Border Name="Border" BorderThickness="0" Margin="0" Padding="0,0,0,4"
                                    BorderBrush="{DynamicResource TabItem.Selected.Border}"
                                    CornerRadius="0,0,0,0" HorizontalAlignment="Center"
                                    VerticalAlignment="Center">
                            <ContentPresenter x:Name="ContentSite" ContentSource="Header"
                                        HorizontalAlignment="Center" />
                        </Border>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsSelected" Value="True">
                            <!-- Setter TargetName="Border" Property="Background"
                                    Value="{StaticResource UWPTab.SelectedColor}"/ -->
                            <Setter TargetName="Border" Property="BorderBrush"
                                        Value="{StaticResource TabItem.Selected.Border}" />
                            <Setter TargetName="Border" Property="BorderThickness" Value="0,0,0,2" />
                            <Setter TargetName="ContentSite" Property="TextBlock.Foreground"
                                        Value="{StaticResource UWPTab.SelectedTextColor}" />
                        </Trigger>
                        <Trigger Property="IsSelected" Value="False">
                            <!-- Setter TargetName="Panel" Property="Background"
                                    Value="{StaticResource UWPTab.UnSelectedColor}"/ -->
                            <Setter TargetName="ContentSite" Property="TextBlock.Foreground"
                                        Value="{StaticResource UWPTab.UnSelectedTextColor}" />
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="True">
                            <Setter TargetName="Panel" Property="Visibility" Value="Visible" />
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter TargetName="Panel" Property="Visibility" Value="Visible" />
                            <Setter TargetName="ContentSite" Property="Visibility" Value="Hidden" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- 
        This is the style for the TitleBar Buttons in the top right corner of the window. They're the Close, Minimize, Restore, Maximize buttons
        The actual button glyph is determined by a tag attribute that is set on the specific instance of the control.
     -->
    <SolidColorBrush x:Key="TitleBarButton.MouseOver.Foreground" Color="#FF0F7FD6" />
    <SolidColorBrush x:Key="TitleBarButton.MouseOver.Background" Color="#FF0F7FD6" />
    <SolidColorBrush x:Key="TitleBarButton.MouseOver.Border" Color="#FF0F7FD6" />
    <Style x:Key="TitleBarButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{x:Static SystemParameters.WindowCaptionButtonWidth}" />
        <Setter Property="Margin" Value="5,0,5,0"
 />
        <Setter Property="Foreground" Value="{DynamicResource WindowTextBrush}" />
        <Setter Property="Padding" Value="0" />
        <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True" />
        <Setter Property="IsTabStop" Value="False" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="border" Background="Transparent" BorderThickness="0" SnapsToDevicePixels="true" Width="{TemplateBinding Width}" Height="{TemplateBinding Height}">
                        <Viewbox Name="ContentViewbox" Stretch="Uniform">
                            <Path Name="ContentPath" Data="" Stroke="{Binding Path=Foreground, RelativeSource={RelativeSource AncestorType={x:Type Button}}}" StrokeThickness="1.25"/>
                        </Viewbox>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Menu">
                            <Setter TargetName="ContentPath" Property="Data" Value="M 0.13587328,0.135839 H 1.1889508 1.1846526 M 0.13587328,1.1870776 H 1.1889508 1.1846526 M 0.13587328,0.6614583 H 1.1889508 1.1846526" />
                            <Setter TargetName="ContentViewbox" Property="Height" Value="15" />
                            <Setter TargetName="ContentPath" Property="StrokeThickness" Value="0.271678" />
                            <Setter TargetName="ContentPath" Property="StrokeLineJoin" Value="Round" />
                            <Setter TargetName="ContentPath" Property="StrokeStartLineCap" Value="Round" />
                            <Setter TargetName="ContentPath" Property="StrokeEndLineCap" Value="Round" />
                        </Trigger>
                        <Trigger Property="Tag" Value="Maximize">
                            <Setter TargetName="ContentPath" Property="Data" Value="M 1.558333,0.5 H 8.199374 C 8.785691,0.5 9.257708,0.972017 9.257708,1.558334 V 8.331666 C 9.257708,8.917983 8.785691,9.39 8.199374,9.39 H 1.558333 C 0.972017,9.39 0.5,8.917983 0.5,8.331666 V 1.558334 C 0.5,0.972017 0.972017,0.5 1.558333,0.5 Z" />
                            <Setter TargetName="ContentViewbox" Property="Height" Value="10" />
                        </Trigger>
                        <Trigger Property="Tag" Value="Restore">
                            <Setter TargetName="ContentPath" Property="Data" Value="M 0.5,2.5 H 7.5 V 9.5 H 0.5 Z M 2.5,2.5 V 0.5 H 9.5 V 7.5 H 7.5" />
                            <Setter TargetName="ContentViewbox" Property="Height" Value="10" />
                        </Trigger>
                        <Trigger Property="Tag" Value="Minimize">
                            <Setter TargetName="ContentPath" Property="Data" Value="M 0,0.5 H 10" />
                            <Setter TargetName="ContentViewbox" Property="Width" Value="10" />
                        </Trigger>
                        <Trigger Property="Tag" Value="Close">
                            <Setter TargetName="ContentPath" Property="Data" Value="M 0.35355339,0.35355339 9.3535534,9.3535534 M 0.35355339,9.3535534 9.3535534,0.35355339" />
                            <Setter TargetName="ContentViewbox" Property="Height" Value="10" />
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="Foreground" Value="{DynamicResource TitleBarButton.MouseOver.Foreground}" />
                            <Setter TargetName="ContentPath" Property="Effect">
                                <Setter.Value>
                                    <DropShadowEffect Color="#FF0F7FD6" ShadowDepth="0" Opacity="1" BlurRadius="10"/>
                                </Setter.Value>
                            </Setter>
                        </Trigger>
                        <MultiTrigger>
                            <MultiTrigger.Conditions>
                                <Condition Property="IsMouseOver" Value="True" />
                                <Condition Property="Tag" Value="Close" />
                            </MultiTrigger.Conditions>
                            <MultiTrigger.Setters>
                                <Setter Property="Foreground" Value="Red" />
                                <Setter TargetName="ContentPath" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="Red" ShadowDepth="0" Opacity="1"/>
                                    </Setter.Value>
                                </Setter>
                            </MultiTrigger.Setters>
                        </MultiTrigger>
                        <MultiTrigger>
                            <MultiTrigger.Conditions>
                                <Condition Property="IsPressed" Value="True" />
                                <Condition Property="Tag" Value="Close" />
                            </MultiTrigger.Conditions>
                            <MultiTrigger.Setters>
                                <Setter Property="Foreground" Value="Red" />
                                <Setter TargetName="ContentPath" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="Red" ShadowDepth="0" Opacity="1"/>
                                    </Setter.Value>
                                </Setter>
                            </MultiTrigger.Setters>
                        </MultiTrigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <DataTrigger
                        Binding="{Binding IsActive, RelativeSource={RelativeSource AncestorType=Window}}"
                        Value="False">
                <Setter Property="Foreground" Value="#FFAAAAAA" />
            </DataTrigger>
        </Style.Triggers>
    </Style>

    <!-- This is the style for the "hamburger" menu button in the top left corner of the window -->
    <Style x:Key="BurgerButtonStyle" TargetType="Button">
        <Setter Property="Foreground" Value="{DynamicResource WindowTextBrush}" />
        <Setter Property="Width" Value="{x:Static SystemParameters.WindowCaptionButtonWidth}" />
        <Setter Property="Height" Value="{x:Static SystemParameters.WindowCaptionButtonHeight}" />
        <Setter Property="Padding" Value="0" />
        <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True" />
        <Setter Property="IsTabStop" Value="False" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="border" Background="Transparent" BorderThickness="0" SnapsToDevicePixels="true" CornerRadius="8,0,0,0">
                        <ContentPresenter x:Name="contentPresenter" Margin="0"
                                    HorizontalAlignment="Center" VerticalAlignment="Center"
                                    Focusable="False" RecognizesAccessKey="True" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="Foreground" Value="{DynamicResource TitleBarButton.MouseOver.Background}" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="true">
                            <Setter TargetName="border" Property="Background" Value="{DynamicResource PressedOverlayBackgroundBrush}" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <DataTrigger
                        Binding="{Binding IsActive, RelativeSource={RelativeSource AncestorType=Window}}"
                        Value="False">
                <Setter Property="Foreground" Value="#FFAAAAAA" />
            </DataTrigger>
        </Style.Triggers>
    </Style>

    <!-- MenuBarButton style for entries in the left-hand menu that is part of the NCT9-1-1 template -->
    <SolidColorBrush x:Key="MenuBarButton.MouseOver.Background" Color="#FF005FB8" />
    <SolidColorBrush x:Key="MenuBarButton.MouseOver.Border" Color="#FF005FB8" />
    <SolidColorBrush x:Key="MenuBarButton.MouseOver.Foreground" Color="White" />
    <SolidColorBrush x:Key="MenuBarButton.Text.Foreground" Color="Black" />
    <Style x:Key="MenuBarButtonStyle" TargetType="Button">
        <Setter Property="Foreground" Value="{StaticResource MenuBarButton.Text.Foreground}" />
        <Setter Property="Padding" Value="0" />
        <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True" />
        <Setter Property="Padding" Value="8,4,4,8" />
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="0,4,0,4"/>
        <Setter Property="IsTabStop" Value="False" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                    <Border x:Name="border" Background="Transparent" BorderThickness="0"
                                SnapsToDevicePixels="true">
                        <ContentPresenter x:Name="contentPresenter"
                                    Margin="{TemplateBinding Padding}" HorizontalAlignment="Center"
                                    VerticalAlignment="Center" Focusable="False" RecognizesAccessKey="True" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="true">
                            <Setter Property="Foreground"
                                        Value="{DynamicResource MenuBarButton.MouseOver.Foreground}" />
                            <Setter TargetName="border" Property="Background"
                                        Value="{DynamicResource MenuBarButton.MouseOver.Background}" />
                            <Setter TargetName="border" Property="BorderBrush"
                                        Value="{DynamicResource MenuBarButton.MouseOver.Border}" />
                            <Setter TargetName="border" Property="CornerRadius" Value="4" />
                        </Trigger>
                        <Trigger Property="IsPressed" Value="true">
                            <Setter TargetName="border" Property="Background"
                                        Value="{DynamicResource PressedOverlayBackgroundBrush}" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <DataTrigger
                        Binding="{Binding IsActive, RelativeSource={RelativeSource AncestorType=Window}}"
                        Value="False">
                <Setter Property="Foreground" Value="#FFAAAAAA" />
            </DataTrigger>
        </Style.Triggers>
    </Style>

    <!-- Scrollbar styles -->
    <Style x:Key="ScrollBarTrackThumb" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch"
                                    Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="CornerScrollBarRectangle" CornerRadius="5"
                                    HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto"
                                    Height="Auto" Margin="0,1,0,1" Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="CornerScrollBarRectangle" Property="Width"
                                        Value="Auto" />
                            <Setter TargetName="CornerScrollBarRectangle" Property="Height"
                                        Value="6" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="#ADABAB" />
        <Setter Property="Background" Value="Transparent" />
        <Setter Property="Width" Value="7" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>
                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true"
                                    Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}"
                                            Style="{DynamicResource ScrollBarTrackThumb}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand"
                                            Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand"
                                            Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ButtonSelectBrush}" TargetName="Thumb"
                                        Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource DarkBrush}" TargetName="Thumb"
                                        Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command"
                                        Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command"
                                        Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>
'@
        }
        #endregion

        #region Build the GUI
        try {
            $WPFGui = [hashtable]::Synchronized( (New-WPFDialog -XamlData $WPFXamL -Resources $ResourceXaML) )
            $WPFGui.Add('ResourceXaML', $ResourceXaML)
        }
        catch {
            $failed = $true
        }

        $WPFGui.Add('hWnd', $null)
        $WPFGui.Add('AsyncResult', [PSCustomObject]@{
                Success = $false
                Message = ""
            })
        #endregion

        #region Titlebar buttons
        $WPFGui.MinimizeButton.add_Click( {
                $WPFGui.UI.WindowState = 'Minimized'
            })

        $WPFGui.RestoreButton.add_Click( {
                $WPFGui.UI.WindowState = 'Normal'
                $WPFGui.MaximizeButton.Visibility = 'Visible'
                $WPFGui.RestoreButton.Visibility = 'Collapsed'
            })

        $WPFGui.MaximizeButton.add_Click( {
                $WPFGui.UI.WindowState = 'Maximized'
                $WPFGui.MaximizeButton.Visibility = 'Collapsed'
                $WPFGui.RestoreButton.Visibility = 'Visible'
            })
        $WPFGui.CloseButton.add_Click( {
                $WPFGui.UI.Close()
            })
        #endregion Titlebar buttons

        #region Menu Buttons
        $WPFGui.SaveLogs.add_Click( {
                # When clicked, save the Activity Log to a file.
                $FileNameParameters = @{
                    Title    = 'New Log File Name'
                    Filter   = 'LOG Files (*.LOG)|*.log|HTML Files (*.html)|*.html|RTF Files (*.rtf)|*.rtf'
                    FileName = "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
                    Save     = $true
                }
                $FileName = Get-FileName @FileNameParameters
                if ( $FileName ) {
                    $Extension = ([System.IO.FileInfo]$FileName).Extension
                    $Format = $Extension.Replace('.', '').Replace('log', 'txt')
                    Save-FlowDocument -Document $WPFGui.Output.Document -Format $Format -FileName $FileName -Title "PoSH GUI Template logs $(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')"
                }
            })
        $WPFGui.MenuExit.add_Click( {
                $WPFGui.UI.Close()
            })
        #endregion

        #region Main Program buttons and fields

        $WPFGui.MenuOpen.add_Completed( {
                # Flip the end points of the menu animation so that it will open when clicked and close when clicked again
                $AnimationParts = @('MenuToggle', 'BurgerFlipper', 'BlurPanel')

                foreach ($Part in $AnimationParts) {
                    $To = $WPFGui."$Part".To
                    $From = $WPFGui."$Part".From
                    $WPFGui."$Part".To = $From
                    $WPFGui."$Part".From = $To
                }
            })


        $WPFGui.UI.add_ContentRendered( {
                # Once the window is visible, grab handle to it
                if ( $WPFGui.hWnd -eq $null) {
                    $WPFGui.hWnd = (New-Object System.Windows.Interop.WindowInteropHelper($WPFGui.UI)).Handle
                }
                [System.Win32Util]::SetTop($WPFGui.hWnd)

                # Write an example log entry
                Write-Activity -Prefix 'PoSH GUI Template' -Text 'Example Activity Log Entry' -Stream 'Output'
            })
        #endregion


        # This region  is unique to the example UI and is meant to demonstrate how to code-behind the various controls
        #region Setup items for static comboxes

        # The best way to bind data to list controls - ComboBoxes, ListBoxes, DataGrids, et. al. - is to use an ObservableCollection

        # Create an ObservableCollection for the example DataGrid
        $WPFGui.Add('ExampleGridItemsList', (New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]) )

        # Set the ObservableCollection as the ItemsSource for the DataGrid
        $WPFGui.ExampleGrid.ItemsSource = $WPFGUI.ExampleGridItemsList

        # Some sample data for the grid, in CSV format
        $ExampleGridItems = @'
"CheckBox","Description","Filename","ExtraInfo","RowIsValid"
"True","Lorem ipsum dolor sit","amet.xslx","consectetur adipiscing elit","True"
"False","sed do eiusmod tempor","incididunt.txt","ut labore et dolore magna aliqua.","True"
"True","Ut enim ad minim veniam","quis.doc","nostrud exercitation ullamco","False"
'@ | ConvertFrom-Csv

        # Add each row to the the ObservableCollection. The DataGrid will displat this data automatically
        $ExampleGridItems.Foreach({ $WPFGui.ExampleGridItemsList.Add($_) | Out-Null })


        # The ComboBoxes work similarly to the DataGrid.

        $WPFGui.Add('ComboBox1List', (New-Object System.Collections.ObjectModel.ObservableCollection[string]) )
        $WPFGui.ComboBox1.ItemsSource = $WPFGui.ComboBox1List
        foreach ($BoxItem in ('laboris nisi ut aliquip').Split(' ')) {
            $WPFGUI.ComboBox1List.Add([string]$BoxItem) | Out-Null
        }
        $WPFGui.ComboBox1.Items.Refresh()

        $WPFGui.Add('ComboBox2List', (New-Object System.Collections.ObjectModel.ObservableCollection[string]) )
        $WPFGui.ComboBox2.ItemsSource = $WPFGui.ComboBox2List
        foreach ($BoxItem in ('ex ea commodo consequat').Split(' ')) {
            $WPFGUI.ComboBox2List.Add([string]$BoxItem) | Out-Null
        }
        $WPFGui.ComboBox2.Items.Refresh()

        # Defaulted values for other input types
        $WPFGUI.Add('TextBox1Text', "dolor")
        $WPFGUI.TextBox1.Text = $WPFGUI.TextBox1Text
        $WPFGui.Add('pwd', $ScriptPath)

        $WPFGui.Add('DomainList', (New-Object System.Collections.ObjectModel.ObservableCollection[string]))
        foreach ($Domain in @('Duis aute irure').Split(' ')) {
            $WPFGUI.DomainList.Add($Domain) | Out-Null
        }
        $WPFGUI.UserDomain.ItemsSource = $WPFGUI.DomainList

        # Not used here, but included for completeness. This is a ButtonClick event that can be routed to a given button on the window.
        $WPFGui.Add('ButtonClick', (New-Object -TypeName System.Windows.RoutedEventArgs -ArgumentList $([System.Windows.Controls.Button]::ClickEvent)))
        
        $WPFGUI.SetPath.Add_Click({

                # Show a Folder Selection dialog when clicked.
                $Parameters = @{
                    Title = 'Select the folder containing explorer.exe'
                }
                $ExplorerPath = Get-FolderName @Parameters
                $ExplorerFile = 'explorer.exe'
                if ( -not (Test-Path (Join-Path $ExplorerPath $ExplorerFile))) {
                    $WPFGui.TextBox2.Foreground = "#FFFF0000"
                }
                else {
                    $WPFGui.TextBox2.Foreground = "#FF000000"
                }
                $WPFGui.TextBox2.Text = $(Join-Path $ExplorerPath $ExplorerFile)
            })

        $WPFGui.Execute.add_Click({
                # Run this code when execute is clicked. A sample dialog is shown synchronously, then the variable values are printed asynchronously.
                Set-Blur -On
                $NewDialog = @{
                    DialogTitle = 'Example Dialog' 
                    H1          = "This is a pop-up dialog"
                    DialogText  = "Dialog text should go here"
                    ConfirmText = 'Continue'
                    GetInput    = $false
                    Beep        = $true
                    IsError     = $false
                    Owner       = $WPFGui.UI
                }
                $Dialog = New-MessageDialog @NewDialog
                Set-Blur -Off
                $AsyncParameters = @{
                    Variables = @{
                        WPFGui         = $WPFGui
                        ComboBox1Value = $WPFGui.ComboBox1.SelectedValue
                        ComboBox2Value = $WPFGui.ComboBox2.SelectedValue
                        CheckBox1Check = $WPFGui.CheckBox1.IsChecked
                        TextBox1Text   = $WPFGui.TextBox1.Text
                        TextBox2Text   = $WPFGui.TextBox2.Text
                        Domain         = $WPFGui.UserDomain.SelectedValue
                        Username       = $WPFGui.UserName.Text
                        SecurePassword = $WPFGui.Password.SecurePassword
                        GridDataJSON   = $WPFGui.ExampleGrid.Items | ConvertTo-Json
                    }
                    Code      = {
                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "ComboBox1 Value: $ComboBox1Value"
                        Write-StatusBar -Progress 12.5 -Text "ComboBox1 Value"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "ComboBox2 Value: $ComboBox2Value"
                        Write-StatusBar -Progress 25 -Text "ComboBox2 Value"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "CheckBox1 is $(if (-not $CheckBox1Check) { "not " })checked."
                        Write-StatusBar -Progress 37.5 -Text "TextBox1 Value"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "TextBox1 Text: $TextBox1Text"
                        Write-StatusBar -Progress 50 -Text "TextBox1 Value"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "TextBox2 Text: $TextBox2Text"
                        Write-StatusBar -Progress 62.5 -Text "TextBox2 Value"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "Credential Values: $Domain\$Username $SecurePassword"
                        Write-StatusBar -Progress 87.5 -Text "Credential Values: $Domain\$Username $SecurePassword"
                        Start-Sleep -Seconds 1

                        Write-Activity -Stream 'Output' -Prefix 'Example' -Text "DataGrid Values (as JSON) $GridDataJSON"
                        Write-StatusBar -Progress 100 -Text "DataGrid Values (as JSON)"
                        Start-Sleep -Seconds 1

                        Write-StatusBar -Progress 0 -Text "Ready."
                    }
                }
        
                Invoke-Async @AsyncParameters
            })

        #endregion
        
        if ( -not $Failed ) {
            # Setup async runspace items
            $WPFGui.Host = $host
            $WPFGui.Add('Runspace', [runspacefactory]::CreateRunspace($InitialSessionState))
            $WPFGui.Runspace.ApartmentState = "STA"
            $WPFGui.Runspace.ThreadOptions = "ReuseThread"
            $WPFGui.Runspace.Open()
            $WPFGui.UI.Dispatcher.InvokeAsync{ $WPFGui.UI.ShowDialog() }.Wait()
            $WPFGui.Runspace.Close()
            $WPFGui.Runspace.Dispose()
        }
    })
$psCmd.Runspace = $newRunspace
$data = $psCmd.Invoke()