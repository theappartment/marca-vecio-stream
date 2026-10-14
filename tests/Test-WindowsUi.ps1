param([string]$PreviewVideoPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-ui-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
. (Join-Path $project 'src\MediaCatalog.ps1')
. (Join-Path $project 'src\PlaybackController.ps1')
function Write-AppLog([string]$Message) { }
$source = [IO.File]::ReadAllText((Join-Path $project 'src\MarcaVecioPlayer.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Player parse errors.' }
$xamlAssignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '[xml]$xaml' },$false)
Invoke-Expression $xamlAssignment.Extent.Text
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
foreach ($name in @('VideoListBox','VideoCountText','PriorityFrequencyCombo','GlobalSlideDurationTextBox','UploadCategoryCombo','ContentEnabledCheckBox','ContentPriorityCheckBox','ContentDurationTextBox','SlidePreview','VideoFolderTextBox','VlcPathTextBox','StatusText')) {
    $control = $window.FindName($name)
    if (-not $control) { throw "Missing WPF control: $name" }
    $variableName = $name.Substring(0,1).ToLowerInvariant() + $name.Substring(1)
    Set-Variable -Name $variableName -Value $control
}
$script:UpdatingContentUi = $false
foreach ($name in @('Get-ContentPreviewBitmap','Refresh-VideoList','Show-ContentSelection','Update-Status')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name },$true)
    Invoke-Expression $function.Extent.Text
}
try {
    if ($uploadCategoryCombo.SelectedIndex -ne 0) { throw 'Default upload category is not normal loop.' }
    Add-Type -AssemblyName System.Drawing
    $image = New-Object Drawing.Bitmap(32,20)
    try { $image.Save((Join-Path $folder 'Slide.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
    $videoFolderTextBox.Text = $folder
    Refresh-VideoList
    if ($videoListBox.Items.Count -ne 1) { throw 'WPF content list empty.' }
    $videoListBox.SelectedIndex = 0
    Show-ContentSelection
    if (-not $slidePreview.Source -or -not $contentPriorityCheckBox.IsEnabled -or $contentDurationTextBox.Text -ne '10') { throw 'WPF slide controls or thumbnail failed.' }
    $changes = [pscustomobject]@{ enabled = $true }
    $changes | Add-Member priority $true
    $changes | Add-Member durationSeconds 4
    Update-MediaItem $folder 'Slide.png' $changes
    Refresh-VideoList
    if (-not $videoListBox.SelectedItem.priority) { throw 'WPF selection metadata did not refresh.' }
    Request-MediaDelete $folder 'Slide.png'; Complete-MediaDeletes $folder
    if ([IO.File]::Exists((Join-Path $folder 'Slide.png'))) { throw 'WPF thumbnail locked original file.' }
    if ($PreviewVideoPath) {
        $videoName = 'Reel caffè prova.mp4'
        $videoPath = Join-Path $folder $videoName
        Copy-Item -LiteralPath $PreviewVideoPath -Destination $videoPath
        Update-MediaItem $folder $videoName ([pscustomobject]@{ role='reel' })
        $vlcPathTextBox.Text = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
        Refresh-VideoList
        if (-not $videoListBox.Items[0].previewBitmap) { throw 'WPF reel row thumbnail missing.' }
        $videoListBox.SelectedIndex = 0; Show-ContentSelection
        if (-not $slidePreview.Source -or $contentDurationTextBox.IsEnabled) { throw 'Reel selection preview or controls incorrect.' }
        $firstPreview = Get-MediaPreview $videoPath $vlcPathTextBox.Text
        $written = (Get-Item -LiteralPath $firstPreview).LastWriteTimeUtc
        $secondPreview = Get-MediaPreview $videoPath $vlcPathTextBox.Text
        if ($firstPreview -ne $secondPreview -or (Get-Item -LiteralPath $secondPreview).LastWriteTimeUtc -ne $written) { throw 'Thumbnail cache not reused.' }
        $exclusive = [IO.File]::Open($videoPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
        Request-MediaDelete $folder $videoName; Complete-MediaDeletes $folder
        if ([IO.File]::Exists($videoPath)) { throw 'Reel preview locks source video.' }
    }
    Write-Output 'PASS: WPF controls, content list, selection, metadata, preview without file lock.'
} finally {
    $window.Close()
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-ui-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
