param(
    [ValidateSet('Review', 'Build', 'Render', 'Check', 'Test')]
    [string]$Stage = 'Build'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Build = Join-Path $Root '_report-build'
$Review = Join-Path $Build 'review'
$ReportName = 'CYS4151_Penetration_Testing_Report'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments
        $ResultCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $PreviousPreference }
    if ($ResultCode -ne 0) {
        throw "$Program failed with exit code $ResultCode"
    }
}

if ($Stage -eq 'Review') {
    New-Item -ItemType Directory -Path $Review -Force | Out-Null
    $PdfRows = foreach ($Source in Get-ChildItem -LiteralPath $Root -Filter '*.pdf' -File | Sort-Object Name) {
        if ($Source.BaseName -eq $ReportName) { continue }
        $Destination = Join-Path $Review ($Source.BaseName + '.txt')
        Invoke-Checked -Program 'pdftotext' -Arguments @('-layout', '-enc', 'UTF-8', $Source.FullName, $Destination)
        $PageInfo = & pdfinfo $Source.FullName
        $PageLine = $PageInfo | Select-String '^Pages:\s+(\d+)'
        [PSCustomObject]@{
            Path = $Source.Name
            Pages = [int]$PageLine.Matches[0].Groups[1].Value
            Bytes = $Source.Length
            SHA256 = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash
        }
    }
    $PdfRows | Export-Csv -LiteralPath (Join-Path $Review 'pdf-inventory.csv') -NoTypeInformation -Encoding UTF8

    Add-Type -AssemblyName System.Drawing
    $Seen = @{}
    $ImageNumber = 0
    $ImageRoots = @('ethical hacking screen short', 'rayan screen shorts')
    $ImageRows = foreach ($ImageRoot in $ImageRoots) {
        foreach ($Source in Get-ChildItem -LiteralPath (Join-Path $Root $ImageRoot) -Recurse -File | Sort-Object FullName) {
            if ($Source.Extension -notmatch '^\.(png|jpg|jpeg|webp|bmp|gif|tiff?)$') { continue }
            $ImageNumber++
            $Identifier = 'E{0:D3}' -f $ImageNumber
            $Hash = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash
            $Image = [System.Drawing.Image]::FromFile($Source.FullName)
            try {
                $Relative = $Source.FullName.Substring($Root.Length + 1).Replace('\', '/')
                [PSCustomObject]@{
                    ID = $Identifier
                    Path = $Relative
                    Width = $Image.Width
                    Height = $Image.Height
                    SHA256 = $Hash
                    DuplicateOf = if ($Seen.ContainsKey($Hash)) { $Seen[$Hash] } else { '' }
                }
            }
            finally { $Image.Dispose() }
            if (-not $Seen.ContainsKey($Hash)) { $Seen[$Hash] = $Identifier }
        }
    }
    $ImageRows | Export-Csv -LiteralPath (Join-Path $Review 'image-inventory.csv') -NoTypeInformation -Encoding UTF8
    if (@($PdfRows).Count -ne 7 -or @($ImageRows).Count -ne 90) {
        throw 'Source inventory changed; reconcile the report coverage before proceeding.'
    }
    $Evidence = Join-Path $Build 'evidence'
    $Contacts = Join-Path $Review 'contacts'
    New-Item -ItemType Directory -Path $Evidence, $Contacts -Force | Out-Null
    $UniqueImages = @($ImageRows | Where-Object { -not $_.DuplicateOf })
    foreach ($Entry in $UniqueImages) {
        Copy-Item -LiteralPath (Join-Path $Root $Entry.Path) -Destination (Join-Path $Evidence ($Entry.ID + '.png')) -Force
    }
    $LabelFont = New-Object System.Drawing.Font('Consolas', 22)
    try {
        for ($Offset = 0; $Offset -lt $UniqueImages.Count; $Offset += 4) {
            $Canvas = New-Object System.Drawing.Bitmap(2400, 1500)
            $Graphics = [System.Drawing.Graphics]::FromImage($Canvas)
            try {
                $Graphics.Clear([System.Drawing.Color]::White)
                $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                for ($Tile = 0; $Tile -lt 4 -and ($Offset + $Tile) -lt $UniqueImages.Count; $Tile++) {
                    $Entry = $UniqueImages[$Offset + $Tile]
                    $Image = [System.Drawing.Image]::FromFile((Join-Path $Root $Entry.Path))
                    try {
                        $Left = ($Tile % 2) * 1200
                        $Top = [math]::Floor($Tile / 2) * 750
                        $Scale = [math]::Min(1180.0 / $Image.Width, 690.0 / $Image.Height)
                        $Graphics.DrawString($Entry.ID, $LabelFont, [System.Drawing.Brushes]::Black, ($Left + 10), ($Top + 4))
                        $Rectangle = [System.Drawing.Rectangle]::new([int]($Left + 10), [int]($Top + 45), [int]($Image.Width * $Scale), [int]($Image.Height * $Scale))
                        $Graphics.DrawImage($Image, $Rectangle)
                    }
                    finally { $Image.Dispose() }
                }
                $Sheet = 'sheet-{0:D2}.png' -f ([int]($Offset / 4) + 1)
                $Canvas.Save((Join-Path $Contacts $Sheet), [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally {
                $Graphics.Dispose()
                $Canvas.Dispose()
            }
        }
    }
    finally { $LabelFont.Dispose() }
    $PdfRows | Format-Table Path, Pages -AutoSize
    Write-Output ("Images: {0}; unique image hashes: {1}; exact duplicates: {2}" -f @($ImageRows).Count, $Seen.Count, @($ImageRows | Where-Object DuplicateOf).Count)
    exit 0
}

if ($Stage -eq 'Build') {
    New-Item -ItemType Directory -Path $Build -Force | Out-Null
    Add-Type -AssemblyName System.Drawing
    $Annotations = @{}
    foreach ($Row in Import-Csv -LiteralPath (Join-Path $Root 'report-evidence.csv')) { $Annotations[$Row.ID] = $Row }
    $Images = @(Import-Csv -LiteralPath (Join-Path $Review 'image-inventory.csv'))
    if ($Annotations.Count -ne 80) { throw 'Every unique image needs a reviewed annotation.' }
    function ConvertTo-Tex {
        param([string]$Value)
        $Escaped = $Value.Replace('\', '\textbackslash{}')
        $Escaped = $Escaped.Replace('&', '\&').Replace('%', '\%').Replace('$', '\$').Replace('#', '\#').Replace('_', '\_')
        return $Escaped
    }
    $EvidenceData = [System.Text.StringBuilder]::new()
    $Index = [System.Text.StringBuilder]::new()
    [void]$Index.AppendLine('\small')
    [void]$Index.AppendLine('\begin{longtable}{@{}L{1.1cm}L{1.1cm}L{8.0cm}L{1.5cm}L{3.6cm}@{}}')
    [void]$Index.AppendLine('\toprule ID & Task & Original source file & Figure & SHA-256 prefix \\ \midrule\endhead')
    foreach ($Entry in $Images) {
        $Canonical = if ($Entry.DuplicateOf) { $Entry.DuplicateOf } else { $Entry.ID }
        $Annotation = $Annotations[$Canonical]
        if (-not $Annotation) { throw "Missing annotation: $Canonical" }
        $PathText = ConvertTo-Tex $Entry.Path
        [void]$Index.AppendLine(('{0} & {1} & {2} & \ev{{{3}}} & \texttt{{{4}}} \\' -f $Entry.ID, $Annotation.Task, $PathText, $Canonical, $Entry.SHA256.Substring(0, 12)))
        if ($Entry.DuplicateOf) { continue }
        $Title = ConvertTo-Tex $Annotation.Title
        $Observation = ConvertTo-Tex $Annotation.Observation
        $Limitation = ConvertTo-Tex $Annotation.Limitation
        [void]$EvidenceData.AppendLine(('\expandafter\def\csname EvidenceTitle{0}\endcsname{{{1}}}' -f $Entry.ID, $Title))
        [void]$EvidenceData.AppendLine(('\expandafter\def\csname EvidenceObservation{0}\endcsname{{{1}}}' -f $Entry.ID, $Observation))
        [void]$EvidenceData.AppendLine(('\expandafter\def\csname EvidenceLimitation{0}\endcsname{{{1}}}' -f $Entry.ID, $Limitation))
    }
    [void]$Index.AppendLine('\bottomrule\end{longtable}\normalsize')
    [System.IO.File]::WriteAllText((Join-Path $Build 'evidence-data.tex'), $EvidenceData.ToString(), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $Build 'evidence-index.tex'), $Index.ToString(), [System.Text.UTF8Encoding]::new($false))
    $Findings = @(Import-Csv -LiteralPath (Join-Path $Root 'report-findings.csv'))
    if ($Findings.Count -ne 8 -or @($Findings.ID | Select-Object -Unique).Count -ne 8) { throw 'Expected eight uniquely identified report findings.' }
    $Metrics = [System.Text.StringBuilder]::new()
    foreach ($Severity in @('Critical', 'High', 'Medium', 'Low')) {
        $Count = @($Findings | Where-Object Severity -eq $Severity).Count
        [void]$Metrics.AppendLine(('\newcommand{{\{0}Count}}{{{1}}}' -f $Severity, $Count))
    }
    foreach ($Finding in $Findings) {
        $Risk = [int]$Finding.Likelihood * [int]$Finding.Impact
        $ExpectedSeverity = if ($Risk -ge 20) { 'Critical' } elseif ($Risk -ge 12) { 'High' } elseif ($Risk -ge 6) { 'Medium' } else { 'Low' }
        if ($Finding.Severity -ne $ExpectedSeverity) { throw "Risk-rating mismatch: $($Finding.ID)" }
        foreach ($Identifier in $Finding.Evidence.Split(' ')) {
            if (-not $Annotations.ContainsKey($Identifier)) { throw "Unknown evidence $Identifier in $($Finding.ID)" }
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $Build 'report-metrics.tex'), $Metrics.ToString(), [System.Text.UTF8Encoding]::new($false))
    Push-Location $Root
    try {
        Invoke-Checked -Program 'latexmk' -Arguments @('-xelatex', '-interaction=nonstopmode', '-halt-on-error', '-outdir=_report-build', ($ReportName + '.tex'))
        Copy-Item -LiteralPath (Join-Path $Build ($ReportName + '.pdf')) -Destination (Join-Path $Root ($ReportName + '.pdf')) -Force
    }
    finally { Pop-Location }
    exit 0
}

if ($Stage -eq 'Render') {
    $Pages = Join-Path $Build 'pages'
    New-Item -ItemType Directory -Path $Pages -Force | Out-Null
    Invoke-Checked -Program 'pdftoppm' -Arguments @('-png', '-r', '95', (Join-Path $Root ($ReportName + '.pdf')), (Join-Path $Pages 'page'))
    Add-Type -AssemblyName System.Drawing
    $PageFiles = @(Get-ChildItem -LiteralPath $Pages -Filter 'page-*.png' -File | Sort-Object Name)
    $Font = [System.Drawing.Font]::new('Consolas', 20)
    try {
        for ($Offset = 0; $Offset -lt $PageFiles.Count; $Offset += 6) {
            $Canvas = [System.Drawing.Bitmap]::new(2100, 1840)
            $Graphics = [System.Drawing.Graphics]::FromImage($Canvas)
            try {
                $Graphics.Clear([System.Drawing.Color]::FromArgb(224, 230, 231))
                $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                for ($Tile = 0; $Tile -lt 6 -and ($Offset + $Tile) -lt $PageFiles.Count; $Tile++) {
                    $Image = [System.Drawing.Image]::FromFile($PageFiles[$Offset + $Tile].FullName)
                    try {
                        $Left = ($Tile % 3) * 700
                        $Top = [math]::Floor($Tile / 3) * 920
                        $Scale = [math]::Min(680.0 / $Image.Width, 870.0 / $Image.Height)
                        $Graphics.DrawString(('PDF ' + ($Offset + $Tile + 1)), $Font, [System.Drawing.Brushes]::Black, ($Left + 10), ($Top + 3))
                        $Box = [System.Drawing.Rectangle]::new([int]($Left + 10), [int]($Top + 40), [int]($Image.Width * $Scale), [int]($Image.Height * $Scale))
                        $Graphics.DrawImage($Image, $Box)
                    }
                    finally { $Image.Dispose() }
                }
                $Name = 'overview-{0:D2}.png' -f ([int]($Offset / 6) + 1)
                $Canvas.Save((Join-Path $Pages $Name), [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $Graphics.Dispose(); $Canvas.Dispose() }
        }
    }
    finally { $Font.Dispose() }
    Write-Output ("Rendered {0} report pages and their numbered overview sheets." -f $PageFiles.Count)
    exit 0
}

if ($Stage -eq 'Test') {
    $Jq = Join-Path $Build 'jq.exe'
    $Checksum = Get-Content -LiteralPath (Join-Path $Build 'jq-sha256sum.txt') | Where-Object { $_ -match '\s+\*?jq-windows-amd64\.exe$' } | Select-Object -First 1
    if (-not $Checksum) { throw 'Official jq checksum entry not found.' }
    $Expected = $Checksum.Split(' ')[0]
    if ((Get-FileHash -LiteralPath $Jq -Algorithm SHA256).Hash -ne $Expected) { throw 'jq executable checksum mismatch.' }
    $Checks = Join-Path $Build 'checks'
    New-Item -ItemType Directory -Path $Checks -Force | Out-Null
    $Source = [System.IO.File]::ReadAllText((Join-Path $Root ($ReportName + '.tex')))
    $Filters = [regex]::Matches($Source, "(?s)jq\s+(-[A-Za-z]+)\s+'(.*?)'")
    if ($Filters.Count -ne 4) { throw 'Review the expected four report jq filters before updating the tests.' }
    $FixtureLines = @(
        '{"timestamp":"2026-10-03T16:23:09+0100","event_type":"alert","src_ip":"192.168.50.100","dest_ip":"192.168.50.1","dest_port":80,"alert":{"signature":"ET SCAN Possible Nmap User-Agent Observed"}}'
        'BROKEN JSON RECORD'
        '{"event_type":"stats","stats":{"uptime":123}}'
        '{"timestamp":"2026-10-03T16:23:08+0100","event_type":"alert","src_ip":"192.168.50.250","dest_ip":"192.168.50.40","dest_port":21,"alert":{"signature":"Scanner test event"}}'
    )
    $Fixture = Join-Path $Checks 'synthetic-eve.ndjson'
    [System.IO.File]::WriteAllLines($Fixture, $FixtureLines, [System.Text.UTF8Encoding]::new($false))
    $Outputs = @()
    for ($FilterIndex = 0; $FilterIndex -lt $Filters.Count; $FilterIndex++) {
        $FilterFile = Join-Path $Checks ('filter-' + $FilterIndex + '.jq')
        [System.IO.File]::WriteAllText($FilterFile, $Filters[$FilterIndex].Groups[2].Value, [System.Text.UTF8Encoding]::new($false))
        $InputFile = if ($FilterIndex -eq 0) { $Fixture } else { Join-Path $Checks 'review.ndjson' }
        $Arguments = @($Filters[$FilterIndex].Groups[1].Value, '-f', $FilterFile, $InputFile)
        $Lines = @(& $Jq @Arguments)
        if ($LASTEXITCODE -ne 0) { throw "Report jq filter $FilterIndex failed." }
        $Outputs += ,$Lines
        if ($FilterIndex -eq 0) {
            [System.IO.File]::WriteAllLines((Join-Path $Checks 'review.ndjson'), [string[]]$Lines, [System.Text.UTF8Encoding]::new($false))
        }
    }
    $Diagnostic = $Outputs[1][0] | ConvertFrom-Json
    $RedAlert = $Outputs[2][0] | ConvertFrom-Json
    if ($Outputs[0].Count -ne 4 -or $Outputs[1].Count -ne 1 -or $Diagnostic.source_line -ne 2) { throw 'Parser did not preserve valid records and identify the malformed line.' }
    if ($Outputs[2].Count -ne 1 -or $RedAlert.src_ip -ne '192.168.50.100') { throw 'Red-source filter failed.' }
    if ($Outputs[3].Count -ne 2 -or -not $Outputs[3][0].StartsWith('2026-10-03T16:23:08')) { throw 'Timeline filtering or sorting failed.' }
    Write-Output 'PASS: verified official jq binary; all four report filters passed synthetic valid/malformed-log tests.'
    exit 0
}

if ($Stage -eq 'Check') {
    $Pdf = Join-Path $Root ($ReportName + '.pdf')
    $TextFile = Join-Path $Build ($ReportName + '.txt')
    Invoke-Checked -Program 'pdftotext' -Arguments @('-layout', '-enc', 'UTF-8', $Pdf, $TextFile)
    $Text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8)
    if ($Text -match '[\u2010\u2011\u2012\u2212]') { throw 'PDF contains unsafe hyphen or minus variants.' }
    if ($Text.Contains('??')) { throw 'PDF contains unresolved-reference markers.' }
    $SourceText = [System.IO.File]::ReadAllText((Join-Path $Root ($ReportName + '.tex')))
    if ($SourceText -match '\\includegraphics\[[^\]]*(trim|clip|viewport)|-detail\.png') { throw 'Screenshot cropping is not permitted in this report.' }
    $RecordedInputs = Get-Content -LiteralPath (Join-Path $Build ($ReportName + '.fls')) -Raw
    if ($RecordedInputs -match '-detail\.png') { throw 'Build included a derived crop instead of an original screenshot.' }
    $Flattened = [regex]::Replace($Text, '\s+', ' ').Trim()
    $Blocks = [regex]::Matches($SourceText, '(?s)\\begin\{reportcode\}(.*?)\\end\{reportcode\}')
    foreach ($Block in $Blocks) {
        $Expected = [regex]::Replace($Block.Groups[1].Value, '\s+', ' ').Trim()
        if (-not $Flattened.Contains($Expected)) { throw ('PDF command round-trip mismatch: ' + $Expected.Substring(0, [math]::Min(90, $Expected.Length))) }
    }
    foreach ($Entry in Import-Csv -LiteralPath (Join-Path $Review 'image-inventory.csv')) {
        if (-not $Text.Contains($Entry.ID)) { throw "Missing evidence ID in PDF: $($Entry.ID)" }
        if (-not $Entry.DuplicateOf) {
            $CopyHash = (Get-FileHash -LiteralPath (Join-Path $Build ('evidence/' + $Entry.ID + '.png')) -Algorithm SHA256).Hash
            if ($CopyHash -ne $Entry.SHA256) { throw "Screenshot copy differs from original: $($Entry.ID)" }
        }
    }
    foreach ($Matricule in @('ICTU20241386', 'ICTU20241393', 'ICTU20241377', 'ICTU20241585', 'ICTU20241870')) {
        if (-not $Text.Contains($Matricule)) { throw "Missing cover identity: $Matricule" }
    }
    foreach ($Inventory in @('pdf-inventory.csv', 'image-inventory.csv')) {
        foreach ($Entry in Import-Csv -LiteralPath (Join-Path $Review $Inventory)) {
            $Current = (Get-FileHash -LiteralPath (Join-Path $Root $Entry.Path) -Algorithm SHA256).Hash
            if ($Current -ne $Entry.SHA256) { throw "Original evidence changed: $($Entry.Path)" }
        }
    }
    $Log = Get-Content -LiteralPath (Join-Path $Build ($ReportName + '.log')) -Raw
    if ($Log -match '(^|\n)!|Missing character:|undefined references|Overfull') { throw 'Inspect the LaTeX log for unresolved errors or overflow.' }
    Write-Output ("PASS: full unmodified screenshots, original hashes, identities, 90 evidence IDs, {0} command-block round-trips, PDF hyphens and cross-references." -f $Blocks.Count)
    & pdfinfo $Pdf | Select-String '^Pages:|^Page size:|^File size:'
}