Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "GitHub Desktop")
$windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
Write-Output ("top-windows-found: " + $windows.Count)
foreach ($w in $windows) {
  Write-Output ("WINDOW name='" + $w.Current.Name + "' class=" + $w.Current.ClassName)
  $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Output ("descendants: " + $all.Count)
  foreach ($el in $all) {
    try {
      $t = $el.Current.ControlType.ProgrammaticName -replace 'ControlType\.',''
      $n = $el.Current.Name
      if ($t -match '^(Button|Edit|Window|Dialog|CheckBox|Text)$') {
        Write-Output ("[" + $t + "] name='" + $n + "'")
      }
    } catch {}
  }
}
