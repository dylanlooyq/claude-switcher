' Launches the tray app with no console window. Double-click, or drop a shortcut in shell:startup.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "\claude-switcher.ps1""", 0, False
