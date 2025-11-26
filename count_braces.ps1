$content = Get-Content "lib\screens\map_screen.dart"
$openBraces = ($content | Select-String -Pattern "{").Count
$closeBraces = ($content | Select-String -Pattern "}").Count
Write-Host "Open braces: $openBraces"
Write-Host "Close braces: $closeBraces"