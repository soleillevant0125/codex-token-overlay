@echo off
if not exist "%~dp0dist\win-x64\CodexTokenOverlay.exe" (
 echo Build the portable executable first. See README.context-monitor.zh-CN.md.
 pause
 exit /b 1
)
if not exist "%~dp0local-settings.json" echo {"SettingsVersion":1,"CollapsedPrimaryField":1,"CollapsedSecondaryField":1024,"VisibleFields":1663,"ManualPlacementEnabled":true,"ContextAlertsEnabled":true,"ContextAlertThresholds":[20,10,5]} > "%~dp0local-settings.json"
start "" "%~dp0dist\win-x64\CodexTokenOverlay.exe" --settings "%~dp0local-settings.json"
