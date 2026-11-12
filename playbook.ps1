function Write-PlaybookHeader {
    param(
        [string]$Title,
        [ConsoleColor]$Accent = 'Cyan',
        [ValidateRange(24, 4096)]
        [int]$Width = 128
    )

    $terminalWidth = $Host.UI.RawUI.WindowSize.Width
    if ($terminalWidth -lt 24) { $terminalWidth = $Width }
    $text = "◆ $Title"
    $bodyWidth = [Math]::Min($text.Length + 2, [Math]::Min($Width, $terminalWidth) - 4)
    $lineWidth = $bodyWidth - 2
    Write-Host ''
    Write-Host ('  ╭' + '─' * $bodyWidth + '╮') -ForegroundColor $Accent
    for ($offset = 0; $offset -lt $text.Length; $offset += $lineWidth) {
        $line = $text.Substring($offset, [Math]::Min($lineWidth, $text.Length - $offset))
        Write-Host '  │ ' -ForegroundColor $Accent -NoNewline
        Write-Host $line.PadRight($lineWidth) -ForegroundColor White -NoNewline
        Write-Host ' │' -ForegroundColor $Accent
    }
    Write-Host ('  ╰' + '─' * $bodyWidth + '╯') -ForegroundColor $Accent
}

function playbook {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Selection,
        [Parameter(Position = 1)]
        [string]$Step,
        [string]$Team,
        [string]$Project,
        [ValidateRange(24, 4096)]
        [int]$Width = 128,
        [ValidateSet('normal', 'fast', 'slow', 'instant')]
        [string]$Speed = 'normal',
        [string]$Service = 'navigator',
        [switch]$List,
        [switch]$Recording
    )

    if ($Recording) {
        if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
            Set-PSReadLineOption -PredictionSource None
        }
        function global:prompt {
            $label = Split-Path -Leaf (Get-Location).Path
            $accent = if ($label -eq 'red_team') { 'Red' } else { 'Cyan' }
            Write-Host '╭─' -ForegroundColor $accent -NoNewline
            Write-Host '(' -ForegroundColor DarkGray -NoNewline
            Write-Host $label -ForegroundColor White -NoNewline
            Write-Host ')' -ForegroundColor DarkGray
            Write-Host '╰─' -ForegroundColor $accent -NoNewline
            '❯ '
        }
    }

    $location = if ($Project) { Get-Item -LiteralPath $Project -ErrorAction Stop } else { Get-Item -LiteralPath . }
    if (!$location.PSIsContainer -or $location.PSProvider.Name -ne 'FileSystem') {
        Write-Warning 'Choose a project folder.'
        return
    }
    $candidate = $location
    while ($candidate) {
        $compose = @('docker-compose.yaml', 'docker-compose.yml', 'compose.yaml', 'compose.yml') |
            ForEach-Object { Join-Path $candidate.FullName $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $teams = @(Get-ChildItem -LiteralPath $candidate.FullName -Directory |
            Where-Object {
                $_.Name -in 'blue_team', 'red_team' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'playbooks') -PathType Container)
            } | Sort-Object Name)
        if ($compose -and $teams.Count) { break }
        $candidate = $candidate.Parent
    }
    if (!$candidate) {
        Write-Warning 'No project with a Compose file and team playbooks was found. Use -Project to select one.'
        return
    }

    if ($Selection -in 'blue', 'red', 'blue_team', 'red_team') {
        if ($Team -and $Team.ToLowerInvariant().Replace('_team', '') -ne $Selection.ToLowerInvariant().Replace('_team', '')) {
            Write-Warning 'Choose one team.'
            return
        }
        $Team = $Selection
        $Selection = $Step
    } elseif ($Step) {
        Write-Warning "Use 'playbook <team> <name or number>' or 'playbook <name or number>'."
        return
    }
    if ($Selection -eq 'list') {
        $List = $true
        $Selection = ''
    }
    if ($Team) {
        $Team = $Team.ToLowerInvariant().Replace('_team', '')
        $teams = @($teams | Where-Object Name -eq "${Team}_team")
    } elseif (!$Project) {
        $context = @($teams | Where-Object {
            $location.FullName -eq $_.FullName -or
            $location.FullName.StartsWith(
                $_.FullName + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        if ($context.Count) { $teams = $context }
    }
    if (!$teams.Count) {
        Write-Warning 'That team has no playbooks folder in this project.'
        return
    }

    if ($teams.Count -gt 1 -and !$List) {
        Write-PlaybookHeader -Title ("{0} / TEAMS" -f $candidate.Name.ToUpperInvariant()) -Width $Width
        for ($i = 0; $i -lt $teams.Count; $i++) {
            $label = $teams[$i].Name.Replace('_team', '')
            $accent = if ($label -eq 'red') { 'Red' } else { 'Cyan' }
            Write-Host ('  [{0}] {1}' -f ($i + 1), $label) -ForegroundColor $accent
        }
        $choice = (Read-Host '  Team number or name (Enter cancels)').Trim()
        if (!$choice) { return }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $teams.Count) {
            $teams = @($teams[$number - 1])
        } else {
            $teams = @($teams | Where-Object { $_.Name.Replace('_team', '') -eq $choice })
        }
        if (!$teams.Count) {
            Write-Warning 'Choose a team from the menu.'
            return
        }
    }

    foreach ($entry in $teams) {
        $folder = Join-Path $entry.FullName 'playbooks'
        $playbooks = @(Get-ChildItem -LiteralPath $folder -File |
            Where-Object Extension -in '.yml', '.yaml' | Sort-Object Name)
        $label = $entry.Name.Replace('_team', '')
        if (!$Selection -or $List) {
            $accent = if ($label -eq 'red') { 'Red' } else { 'Cyan' }
            Write-PlaybookHeader -Title ("{0} / {1} TEAM" -f $candidate.Name.ToUpperInvariant(), $label.ToUpperInvariant()) -Accent $accent -Width $Width
            for ($i = 0; $i -lt $playbooks.Count; $i++) {
                $accent = if ($playbooks[$i].BaseName -eq 'deprovision') { 'Yellow' } else { 'White' }
                Write-Host ('  [{0}] ' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
                Write-Host $playbooks[$i].BaseName -ForegroundColor $accent
            }
        }
        if ($List) { continue }
        if (!$playbooks.Count) {
            Write-Warning 'This team has no playbooks yet.'
            return
        }
        if (!$Selection) {
            $Selection = (Read-Host '  Playbook number or name (Enter cancels)').Trim()
            if (!$Selection) { return }
        }

        $number = 0
        if ([int]::TryParse($Selection, [ref]$number)) {
            if ($number -lt 1 -or $number -gt $playbooks.Count) {
                Write-Warning 'Choose a number from the playbook menu.'
                return
            }
            $selected = $playbooks[$number - 1]
        } else {
            $matching = @($playbooks | Where-Object { $_.BaseName -eq $Selection -or $_.Name -eq $Selection })
            if ($matching.Count -ne 1) {
                Write-Warning "Choose a playbook from 'playbook list'."
                return
            }
            $selected = $matching[0]
        }

        $path = '{0}/playbooks/{1}' -f $entry.Name, $selected.Name
        $composeArgs = @(
            'compose', '--project-directory', $candidate.FullName, '-f', $compose,
            'run', '--rm', '-e', "WALKTHROUGH_WIDTH=$Width",
            '-e', "WALKTHROUGH_SPEED=$($Speed.ToLowerInvariant())",
            $Service, 'run', $path, '--enable-prompts', '--', '--step'
        )
        & docker @composeArgs
    }
}
