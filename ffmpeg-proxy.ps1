class Entry {
    [int]$start_s
    [int]$start_ms
    [int]$end_s
    [int]$end_ms
    [bool]$waszero
    [System.Collections.ArrayList]$lines
}

function GetWeb($uri) {
	$response = wget $uri
	
	# DEBUG: write to file
	# $response | export-clixml ((split-path -leaf $uri)+".xml")

	# DEBUG: read from file
	# $response = import-clixml ((split-path -leaf $uri)+".xml")

	$content = $response.content
	if ($content.gettype().Name -eq "Byte[]") {
		$content = [System.Text.Encoding]::UTF8.GetString($response.content)
	} elseif ($response.BaseResponse.CharacterSet -ne "") {
        $content = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding($response.BaseResponse.CharacterSet).GetBytes($response.content))
    }

	return $content.split(10)
}

###########################################################
### parse arguments
###########################################################

$uri = $null
$outfile = "output.srt"

for ($i = 0; $i -lt $args.length; $i++) {
	if ($args[$i] -eq '-i') {
		$uri = $args[$i+1]
		$i++;
	}
	elseif ($args[$i].endswith(".mp4")) {
		$outfile = $args[$i].replace(".mp4",".srt")
	}
}

d:\video\ffmpeg.exe $args

if ($uri -eq $null) {
	write-host "no uri"
	return;
}

###########################################################
### parse main m3u8
###########################################################

$mainm3u8 = GetWeb $uri

if ($mainm3u8 | ? { $_ -match 'TYPE=SUBTITLES,.*,URI="(.*)"' }) {
	$subsuri = $Matches[1]
} else {
	write-host '### ERROR: #EXT-X-MEDIA:TYPE=SUBTITLES,...,URI="..." not found'
	$mainm3u8 | export-clixml error-mainm3u8.xml
	return;
}

###########################################################
### parse subs m3u8
###########################################################

$baseuri = (split-path $uri).replace("\","/")
$subm3u8 = GetWeb ($baseuri + "/" + $subsuri)

if ($subm3u8 | ? { $_ -match 'USP-X-TIMESTAMP-MAP:MPEGTS=(.*),LOCAL=' }) {
	$offset = [int]$matches[1]
} else {
	write-host "### ERROR: USP-X-TIMESTAMP-MAP:MPEGTS= NOT FOUND"
	$subm3u8 | export-clixml error-subm3u8.xml
	return;
}

$webvtturis = $subm3u8 | ? { -not $_.StartsWith('#') -and $_.length -gt 0 }

###########################################################
### parse webvtt files
###########################################################

function SaveEntry([ref]$entries, $currEntry) {
    if ($currEntry -eq $null) {
        return;
    }

    # remove empty lines at end of entry
    while ($currEntry.lines.count -gt 0 -and $currEntry.lines[-1].length -eq 0) {
        $currEntry.lines.RemoveAt($currEntry.lines.count - 1)
    }

    # merge with previous entry or add new entry
    if ($currEntry.wasZero -and $entries.value.length -gt 0 -and -not (compare-object $currEntry.lines $entries.value[-1].lines)) {
        # merge 
        $entries.value[-1].end_s = $currEntry.end_s
        $entries.value[-1].end_ms = $currEntry.end_ms
    } else {
        # add
        $entries.value += $currEntry
    }
}

[Entry[]]$entries = @()
$tsresolution = 90000

$count = $webvtturis.length
for ($i = 0; $i -lt $count; $i++) {
	Write-Progress -Activity Downloading -PercentComplete ($i*100/$count)

	$webvtt = GetWeb ($baseuri + "/" + $webvtturis[$i])

	if ($webvtt[0] -ne "WEBVTT") {
		write-host "### ERROR: EXPECTED LINE 1: 'WEBVTT' IN" $webvtturis[$i]
        $webvtt | export-clixml error-${i}.xml
		return
	}
	if (-not ($webvtt[1] -match 'X-TIMESTAMP-MAP=MPEGTS:(.*),LOCAL:')) {
		write-host "### ERROR: EXPECTED LINE 2: 'X-TIMESTAMP-MAP=MPEGTS:#,LOCAL:' IN" $webvtturis[$i]
        $webvtt | export-clixml error-${i}.xml
		return
	}
	$time = ([int]$Matches[1] - $offset) / $tsresolution
	if ($webvtt[2].length -ne 0) {
		write-host "### ERROR: EXPECTED LINE 3: <empty> IN" $webvtturis[$i]
        $webvtt | export-clixml error-${i}.xml
		return
	}

	[Entry]$currEntry = $null
	for ($j = 3; $j -lt $webvtt.length; $j++) {
		#write-host $j,"[[", $webvtt[$j], "]]"
		if ($webvtt[$j] -match '^([0-9][0-9]):([0-9][0-9]):([0-9][0-9]).([0-9][0-9][0-9]) --> ([0-9][0-9]):([0-9][0-9]):([0-9][0-9]).([0-9][0-9][0-9])') {
			SaveEntry ([ref]$entries) $currEntry
			$currEntry = [Entry]::new()
			$currEntry.start_s = $time + [int]$Matches[3] + 60 * ([int]$Matches[2] + 60 * [int]$Matches[1])
			$currEntry.start_ms = [int]$Matches[4]
			$currEntry.end_s = $time + [int]$Matches[7] + 60 * ([int]$Matches[6] + 60 * [int]$Matches[5])
			$currEntry.end_ms = [int]$Matches[8]
			$currEntry.waszero = $currEntry.start_s -eq $time -and $currEntry.start_ms -eq 0
			$currEntry.lines = [System.Collections.ArrayList]::new()
			#write-host "TIMESTAMP:",$currEntry,$currEntry.waszero
		} else {
			if ($currEntry -eq $null ) {
				if ($webvtt[$j].length -eq 0) {
					continue;
				}
				write-host "### ERROR: EXPECTED TIMESTAMP BEFORE TEXT IN" $webvtturis[$i]
                $webvtt | export-clixml error-${i}.xml
				return;
			}
			[void]$currEntry.lines.add($webvtt[$j])
			#write-host "LINE:",$lines[$j]
		}
	}
    SaveEntry ([ref]$entries) $currEntry
}

###########################################################
### output srt file
###########################################################

$seqnumber = 0
$srtfile = foreach ($entry in $entries) {
    $seqnumber++
	$s1 = 0
	$m1 = [system.math]::DivRem($entry.start_s, 60, [ref]$s1)
	$h1 = [system.math]::DivRem($m1, 60, [ref]$m1)
	$s2 = 0
	$m2 = [system.math]::DivRem($entry.end_s, 60, [ref]$s2)
	$h2 = [system.math]::DivRem($m2, 60, [ref]$m2)
	$timestamp = "{0:d2}:{1:d2}:{2:d2}.{3:d3} --> {4:d2}:{5:d2}:{6:d2}.{7:d3}" -f $h1, $m1, $s1, $entry.start_ms, $h2, $m2, $s2, $entry.end_ms
    write-output $seqnumber
	write-output $timestamp
	foreach ($line in $entry.lines) {
		write-output $line
	}
	write-output ''
}

$srtfile | Out-File -Encoding utf8 $outfile
