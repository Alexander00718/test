' Fully silent launcher - no console flash at all.
Dim sh, here
Set sh = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & here & "\TimeTracker.ps1""", 0, False
