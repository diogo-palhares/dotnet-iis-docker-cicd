@{
    Severity     = @('Error', 'Warning')

    # The deployment scripts are run interactively by an operator and print coloured progress; Write-Host is
    # intentional there (nothing consumes their output through the pipeline).
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
