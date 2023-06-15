# PowerShell GUI Template

This is a template for quickly building Windows 11 styled WPF programs in PowerShell. One would typically do this to add a user-friendly front-end to a complex PowerShell automation. This is broken into several parts. There are XaML files, which define the graphical elements, a PowerShell script file that defines the code elements, and a Visual Studio Project that can be used with Visual Studio to access the WPF Designer.

Screenshots, and a sample video, are available [here](/Screenshots/).

For an additional example of a tool built with this, check out the [VMWare Tag Tool Project](https://github.com/nct911/VMWareTagTool)

## Visual Studio Project
Setup so that you can open it and go directly to the WPF Designer view to edit the Window Contents and layout. This project is for Visual Studio 2022, it's not guaranteed to work with older versions. If you have an older version, though, you can follow this procedure to create project you can use:

1. Create a new WPF project named **PoSH_GUI_Template**
2. Use the **Solution Explorer** to **Add Existing Item...** to your project and add the **DialogPanel.XaML**
3. Use the **Solution Explorer** to **Add Existing Item...** to your project and add the **ControlTemplates.XaML**
4. Replace **App.XaML** with the one from this project.
5. Replace **MainWindow.XaML** with the one from this project.

### XaML Files

- **App.xaml**

    Part of the Visual Studio Project. It contains the require XaML to include the control templates.

- **ControlTemplates.xaml**

    The WPF control templates. These are styled to look, as much as possible, like Windows 11 / WinUI3

- **MainWindow.xaml**

    The Main Window template. It includes the basic sections that are reusable across programs.

- **DialogPanel.xaml**

    The template for the basic Windows 11 styled message dialog.

### PowerShell Script - included functions
- **Invoke-Async**

    This function runs the given code in an asynchronous runspace. This lets you process data in the background while leaving the UI responsive to input

- **New-WPFDialog**
    
    This is a function based on the one from [Brian Posey's Article](http://www.windowsnetworking.com/articles-tutorials/netgeneral/building-powershell-gui-part2.html) on Powershell GUIs. It has been re-factored a bit to return the resulting XaML Reader and controls as a single, named collection.
- **Set-Blur**

    Blur or UN-Blur the main program window
- **Copy-Object**

    Creates a copy of an object to a new location in memory.
- **New-MessageDialog**

    Displays a Windows 11 styled information, error, or simple text input dialog.
- **Write-Activity**

    Writes a colorized entry into the program's activity log
- **Write-StatusBar**

    Writes a status text and progress percentage to the StatusBar area
- **Save-Screenshot**
    
    Saves a screenshot of the selected screen, or of ALL screens in BMP, JPG/JPEG, or PNG format.
- **Get-FileName**
    
    Displays the Win32OpenFile or Win32SaveFile dialog to prompt the user for a FileName selection
- **Get-FolderName**

    Displays a Win32OpenFile dialog that is modified to select a Folder instead of a file.
- **ConvertFrom-FlowDocument**

    Converts a RichTextBox FlowDocument to HTML
- **Save-FlowDocument**

    Saves a RichTextBox FlowDocument in Text, RTF, or HTML format.

