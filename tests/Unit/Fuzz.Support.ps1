#Requires -Version 5.1
<#
    Fuzzing support helpers for ConvertFrom-RobocopyLine robustness testing.
    Deterministic (seeded) so CI runs are reproducible. Not a module function;
    dot-sourced by the fuzz test file only.
    Author  : Yorga Babuscan <yorgabr@gmail.com>
    License : Apache License 2.0
#>

function New-EfcFuzzCorpus {
    <#
    .SYNOPSIS
        Produces a deterministic corpus of mutated / adversarial log lines.
    .PARAMETER Seed
        RNG seed for reproducibility.
    .PARAMETER Count
        Number of fuzzed lines to generate (in addition to the fixed adversarial set).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [int] $Seed  = 1337,
        [int] $Count = 500
    )

    $rng = [System.Random]::new($Seed)

    # --- Building blocks harvested from real robocopy output -------------------
    $actions = @('New File', 'Newer', 'Older', 'Changed', '*EXTRA File',
                 'New Dir', 'ERROR', '', '   ')
    $sizes   = @('0', '1', '1024', '1048576', '9999999999',
                 'NOTANUMBER', '-1', '', '   ', '1.5', '0x400', "$([long]::MaxValue)")
    $paths   = @('C:\data\file.txt',
                 'C:\path with spaces\a b c.dat',
                 'C:\dados\arquivo-ção-üñ.txt',
                 '\\SERVER\share\deep\nested\path.bin',
                 'C:\',
                 '', '   ',
                 'D:\emoji-name.txt',
                 'C:\very' + ('long\' * 60) + 'path.txt')
    $separators = @("`t", "`t`t", "`t   ", "   `t", ' ', '')
    $prefixes   = @('', "`t", "`t  ", '100%', '2024/01/15 09:32:01', '   ', "`t`t")

    # --- Fixed adversarial set (regression-critical edge cases) ----------------
    $fixed = @(
        '',
        ' ',
        "`t",
        "`n",
        "`r`n",
        '------------------------------',
        '   ROBOCOPY     ::     Robust File Copy for Windows',
        '  Total    Copied   Skipped  Mismatch    FAILED    Extras',
        'ERROR 5 (0x00000005) Accessing Source Directory',
        "`tNew File `t`t`t1024`tC:\data\x.txt",
        "New File`t1024`tno-leading-whitespace.txt",
        ("A" * 5000),                          # pathological long line
        "New File `t1024`tC:\ctrl`0char.txt",  # embedded null
        "New File `t $([long]::MaxValue) `tC:\huge.bin"
    )

    $generated = for ($i = 0; $i -lt $Count; $i++) {
        $prefix = $prefixes[$rng.Next($prefixes.Count)]
        $action = $actions[$rng.Next($actions.Count)]
        $sep1   = $separators[$rng.Next($separators.Count)]
        $size   = $sizes[$rng.Next($sizes.Count)]
        $sep2   = $separators[$rng.Next($separators.Count)]
        $path   = $paths[$rng.Next($paths.Count)]

        '{0}{1}{2}{3}{4}{5}' -f $prefix, $action, $sep1, $size, $sep2, $path
    }

    return @($fixed + $generated)
}
