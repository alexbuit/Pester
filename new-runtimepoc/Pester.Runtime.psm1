. $PSScriptRoot\Pester.Utility.ps1
. $PSScriptRoot\..\Functions\Pester.SafeCommands.ps1
. $PSScriptRoot\Pester.Types.ps1

if (notDefined PesterPreference) {
    $PesterPreference = [PesterConfiguration]::Default
}
else {
    $PesterPreference = [PesterConfiguration] $PesterPreference
}

$state = [PSCustomObject] @{
    # indicate whether or not we are currently
    # running in discovery mode se we can change
    # behavior of the commands appropriately
    Discovery           = $false

    CurrentBlock        = $null
    CurrentTest         = $null

    Plugin              = $null
    PluginConfiguration = $null
    Configuration       = $null

    TotalStopWatch      = $null
    UserCodeStopWatch   = $null
    FrameworkStopWatch  = $null

    ExpandName          = {
        param([string]$Name, [HashTable]$Data)

        $n = $Name
        foreach ($pair in $Data.GetEnumerator()) {
            $n = $n -replace "<$($pair.Key)>", "$($pair.Value)"
        }
        $n
    }
}


function Reset-TestSuiteState {
    # resets the module state to the default
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Resetting all state to default."
    }
    $state.Discovery = $false

    $state.Plugin = $null
    $state.PluginConfiguration = $null
    $state.Configuration = $null

    $state.CurrentBlock = $null
    $state.CurrentTest = $null
    Reset-Scope
    Reset-TestSuiteTimer
}

function Reset-PerContainerState {
    param(
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")] $RootBlock
    )
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Resetting per container state."
    }
    $state.CurrentBlock = $RootBlock
    Reset-Scope
}

function Find-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("BlockContainer")][PSObject[]] $BlockContainer,
        [PSTypeName("Filter")] $Filter,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState
    )

    # don't scope InvokedNonInteractively to script we want the functions
    # that are called by this to see the value but it should not be
    # persisted afterwards so we don't have to reset it to $false
    $InvokedNonInteractively = $true

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope DiscoveryCore "Running just discovery."
    }
    $found = Discover-Test -BlockContainer $BlockContainer -Filter $Filter -SessionState $SessionState

    foreach ($f in $found) {
        ConvertTo-DiscoveredBlockContainer -Block $f
    }
}

function ConvertTo-DiscoveredBlockContainer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")] $Block
    )

    # takes a root block and converts it to a discovered block container
    # that we can publish from Find-Test, because keeping everything a block makes the internal
    # code simpler
    $container = $Block.BlockContainer
    $content = tryGetProperty $container Content
    $type = tryGetProperty $container Type

    # TODO: Add other properties that are relevant to found tests
    $b = $Block | &$SafeCommands['Select-Object'] -ExcludeProperty @(
        "Parent"
        "Name"
        "Tag"
        "First"
        "Last"
        "StandardOutput"
        "Passed"
        "Skipped"
        "Executed"
        "Path",
        "StartedAt",
        "Duration",
        "Aggregated*"
    ) -Property @(
        @{n = "Content"; e = { $content } }
        @{n = "Type"; e = { $type } },
        @{n = "PSTypename"; e = { "DiscoveredBlockContainer" } }
        '*'
    )

    $b
}

function ConvertTo-ExecutedBlockContainer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")] $Block
    )

    # takes a root block and converts it to a executed block container
    # that we can publish from Invoke-Test, because keeping everything a block makes the internal
    # code simpler
    $container = $Block.BlockContainer
    $content = tryGetProperty $container Content
    $type = tryGetProperty $container Type

    $properties = @{
        Content = $content
        Type = $type
    }

    if ("file" -eq $Block.BlockContainer.Type) {
        $properties.Add("Path", $content)
    }

    $excluded = @(
        "Parent"
        "Name"
        "Tag"
        "First"
        "Last"
        "StandardOutput"
        "Path" # <- this is abc.gef on Block, not filepath
        "Order"
    )

    foreach ($b in @($Block)) {
        $o = @{}
        foreach ($p in $Block.PSObject.Properties) {
            if ($p.Name -notin $excluded) {
                $o.Add($p.Name, $p.Value)
            }
        }

        foreach ($p in $properties.GetEnumerator()) {
            $o.Add($p.Key, $p.Value)
        }

        New_PSObject -Type "ExecutedBlockContainer" -Property $o
    }
}


# endpoint for adding a block that contains tests
# or other blocks
function New-Block {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Name,
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock,
        [String[]] $Tag = @(),
        [HashTable] $FrameworkData = @{ },
        [Switch] $Focus,
        [String] $Id,
        [Switch] $Skip
    )

    Switch-Timer -Scope Framework
    $overheadStartTime = $state.FrameworkStopWatch.Elapsed
    $blockStartTime = $state.UserCodeStopWatch.Elapsed

    Push-Scope -Scope (New-Scope -Name $Name -Hint Block)
    $path = @(foreach ($h in (Get-ScopeHistory)) { $h.Name })
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Entering path $($path -join '.')"
    }

    $block = $null

    $previousBlock = Get-CurrentBlock

    if (-not $previousBlock.FrameworkData.ContainsKey("PreviouslyGeneratedBlocks")) {
        $previousBlock.FrameworkData.Add("PreviouslyGeneratedBlocks", @{ })
    }
    $hasExternalId = -not [string]::IsNullOrWhiteSpace($Id)
    $Id = if (-not $hasExternalId) {
        $previouslyGeneratedBlocks = $previousBlock.FrameworkData.PreviouslyGeneratedBlocks
        Get-Id -ScriptBlock $ScriptBlock -Previous $previouslyGeneratedBlocks
    }
    else {
        $Id
    }

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope DiscoveryCore "Adding block $Name to discovered blocks"
    }

    # the tests are identified based on the start position of their script block
    # so in case user generates tests (typically from foreach loop)
    # we are not able to distinguish between test generated during first iteration of the
    # loop and second iteration of the loop. this is not a problem for the discovery, but it
    # is problem for the run, because then we get ambiguous reference to a test
    # to avoid forcing the user to provide the id in cases where the list of things is the same
    # between discovery and run, we look at the latest test in this block and if it comes from the same
    # line we add one to the counter and use that as an implicit Id.
    # and since there can be multiple tests in the foreach, we add one item per test, and key
    # them by the position
    # TODO: in the new-new-runtime we should be able to remove this because the invocation will be sequential
    $FrameworkData.Add("PreviouslyGeneratedTests", @{ })

    $block = New-BlockObject -Name $Name -Path $path -Tag $Tag -ScriptBlock $ScriptBlock -FrameworkData $FrameworkData -Focus:$Focus -Id $Id -Skip:$Skip
    # we attach the current block to the parent
    Add-Block -Block $block
    Set-CurrentBlock -Block $block
    try {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope DiscoveryCore "Discovering in body of block $Name"
        }
        & $ScriptBlock
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope DiscoveryCore "Finished discovering in body of block $Name"
        }
    }
    finally {
        Set-CurrentBlock -Block $previousBlock
        $null = Pop-Scope
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Left block $Name"
        }
        $block.DiscoveryDuration = ($state.FrameworkStopWatch.Elapsed - $overheadStartTime) + ($state.UserCodeStopWatch.Elapsed - $blockStartTime)
    }
}

function Invoke-Block ($previousBlock) {
    Switch-Timer -Scope Framework
    $overheadStartTime = $state.FrameworkStopWatch.Elapsed
    $blockStartTime = $state.UserCodeStopWatch.Elapsed

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Entering path $($path -join '.')"
    }

    foreach ($item in $previousBlock.Order) {
        if ('Test' -eq $item.ItemType) {
            Invoke-TestItem -Test $item
        }
        else {
            $block = $item
            if (-not $previousBlock.FrameworkData.ContainsKey("PreviouslyGeneratedBlocks")) {
                $previousBlock.FrameworkData.Add("PreviouslyGeneratedBlocks", @{ })
            }
            $hasExternalId = -not [string]::IsNullOrWhiteSpace($Id)
            $Id = if (-not $hasExternalId) {
                    $previouslyGeneratedBlocks = $previousBlock.FrameworkData.PreviouslyGeneratedBlocks
                    Get-Id -ScriptBlock $block.ScriptBlock -Previous $previouslyGeneratedBlocks
                }
                else {
                    $Id
                }

            Set-CurrentBlock -Block $block
            try {
                if (-not $block.ShouldRun) {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope Runtime "Block '$($block.Name)' is excluded from run, returning"
                    }
                    continue
                }

                $block.ExecutedAt = [DateTime]::Now
                $block.Executed = $true
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    Write-PesterDebugMessage -Scope Runtime "Executing body of block '$($block.Name)'"
                }
                # TODO: no callbacks are provided because we are not transitioning between any states,
                # it might be nice to add a parameter to indicate that we run in the same scope
                # so we can avoid getting and setting the scope on scriptblock that already has that
                # scope, which is _potentially_ slow because of reflection, it would also allow
                # making the transition callbacks mandatory unless the parameter is provided
                $frameworkSetupResult = Invoke-ScriptBlock `
                    -OuterSetup @(
                    if ($block.First) { selectNonNull $state.Plugin.OneTimeBlockSetupStart }
                ) `
                    -Setup @( selectNonNull $state.Plugin.EachBlockSetupStart ) `
                    -ScriptBlock { } `
                    -Context @{
                    Context = @{
                        # context that is visible to plugins
                        Block         = $block
                        Test          = $null
                        Configuration = $state.PluginConfiguration
                    }
                }

                if ($frameworkSetupResult.Success) {
                    # this craziness makes one extra scope that is bound to the user session state
                    # and inside of it the Invoke-Block is called recursively. Ultimately this invokes all blocks
                    # in their own scope like this:
                    # & { # block 1
                    #     . block 1 setup
                    #     & { # block 2
                    #         . block 2 setup
                    #         & { # block 3
                    #             . block 3 setup
                    #             & { # test one
                    #                 . test 1 setup
                    #                 . test1
                    #             }
                    #         }
                    #     }
                    # }

                    $sb = {
                        param($______pester_invoke_block_parameters)
                        & $______pester_invoke_block_parameters.Invoke_Block -previousBlock $______pester_invoke_block_parameters.Block
                    }

                    function Set-SessionStateFromScriptBlock ($OriginScriptBlock, $ScriptBlock) {
                        $flags = [Reflection.BindingFlags]'Instance,NonPublic'

                        # $sessionStateInternal = $ScriptBlock.SessionStateInternal
                        $sessionStateInternal = [ScriptBlock].GetProperty(
                            'SessionStateInternal', $flags).GetValue($OriginScriptBlock, $null)

                        # $ScriptBlock.SessionStateInternal = $sessionStateInternal
                        [ScriptBlock].GetProperty(
                            'SessionStateInternal', $flags).SetValue(
                                $ScriptBlock, $SessionStateInternal)
                    }

                    Set-SessionStateFromScriptBlock -OriginScriptBlock $block.ScriptBlock -ScriptBlock $sb

                    $result = Invoke-ScriptBlock `
                        -ScriptBlock $sb `
                        -OuterSetup $( if (-not (Is-Discovery) -and (-not $Block.Skip)) {
                            combineNonNull @(
                                $previousBlock.EachBlockSetup
                                $block.OneTimeTestSetup
                            )
                        }) `
                        -OuterTeardown $( if (-not (Is-Discovery) -and (-not $Block.Skip)) {
                            combineNonNull @(
                                $block.OneTimeTestTeardown
                                $previousBlock.EachBlockTeardown
                            )
                        } ) `
                        -Context @{
                            ______pester_invoke_block_parameters = @{
                                Invoke_Block = ${function:Invoke-Block}
                                Block = $block
                            }
                        } `
                        -ReduceContextToInnerScope `
                        -MoveBetweenScopes `
                        -OnUserScopeTransition { Switch-Timer -Scope UserCode } `
                        -OnFrameworkScopeTransition { Switch-Timer -Scope Framework } `
                        -Configuration $state.Configuration

                    $block.OwnPassed = $result.Success
                    $block.StandardOutput = $result.StandardOutput

                    $block.ErrorRecord = $result.ErrorRecord
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope Runtime "Finished executing body of block $Name"
                    }
                }

                $frameworkEachBlockTeardowns = @( selectNonNull $state.Plugin.EachBlockTeardownEnd )
                $frameworkOneTimeBlockTeardowns = @( if ($block.Last) { selectNonNull $state.Plugin.OneTimeBlockTeardownEnd } )
                # reverse the teardowns so they run in opposite order to setups
                [Array]::Reverse($frameworkEachBlockTeardowns)
                [Array]::Reverse($frameworkOneTimeBlockTeardowns)


                # setting those values here so they are available for the teardown
                # BUT they are then set again at the end of the block to make them accurate
                # so the value on the screen vs the value in the object is slightly different
                # with the value in the result being the correct one
                $block.Duration = $state.UserCodeStopWatch.Elapsed - $blockStartTime
                $block.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
                $frameworkTeardownResult = Invoke-ScriptBlock `
                    -ScriptBlock { } `
                    -Teardown $frameworkEachBlockTeardowns `
                    -OuterTeardown $frameworkOneTimeBlockTeardowns `
                    -Context @{
                    Context = @{
                        # context that is visible to plugins
                        Block         = $block
                        Test          = $null
                        Configuration = $state.PluginConfiguration
                    }
                }

                if (-not $frameworkSetupResult.Success -or -not $frameworkTeardownResult.Success) {
                    Assert-Success -InvocationResult @($frameworkSetupResult, $frameworkTeardownResult) -Message "Framework failed"
                }
            }
            finally {
                Set-CurrentBlock -Block $previousBlock
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    Write-PesterDebugMessage -Scope Runtime "Left block $Name"
                }
                $block.Duration = $state.UserCodeStopWatch.Elapsed - $blockStartTime
                $block.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    Write-PesterDebugMessage -Scope Timing "Block duration $($block.Duration.TotalMilliseconds)ms"
                    Write-PesterDebugMessage -Scope Timing "Block framework duration $($block.FrameworkDuration.TotalMilliseconds)ms"
                    Write-PesterDebugMessage -Scope Runtime "Leaving path $($path -join '.')"
                }
            }
        }
    }
}

# endpoint for adding a test
function New-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $Name,
        [Parameter(Mandatory = $true, Position = 1)]
        [ScriptBlock] $ScriptBlock,
        [String[]] $Tag = @(),
        [System.Collections.IDictionary] $Data = @{ },
        [String] $Id,
        [Switch] $Focus,
        [Switch] $Skip
    )
    # keep this at the top so we report as much time
    # of the actual test run as possible
    $overheadStartTime = $state.FrameworkStopWatch.Elapsed
    $testStartTime = $state.UserCodeStopWatch.Elapsed
    Switch-Timer -Scope Framework

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Entering test $Name"
    }
    Push-Scope -Scope (New-Scope -Name $Name -Hint Test)
    try {
        $path = foreach ($h in (Get-ScopeHistory)) { $h.Name }
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Entering path $($path -join '.')"
        }

        # TODO: this id stuff is probably not needed, we don't need to relay tests together here, it was useful before for new runtime that was executing the code twice, but now we are just going by the test order so we don't need the id anymore
        # $hasExternalId = -not [string]::IsNullOrWhiteSpace($Id)
        # if (-not $hasExternalId) {
        #     $Id = 0
        #     $PreviouslyGeneratedTests = (Get-CurrentBlock).FrameworkData.PreviouslyGeneratedTests

        #     if ($null -eq $PreviouslyGeneratedTests) {
        #         # TODO: this enables tests that are not in a block to run. those are outdated tests in my
        #         # test suite, so this should be imho removed later, and the tests rewritten
        #         $PreviouslyGeneratedTests = @{ }

        #     }

        #     $Id = Get-Id -ScriptBlock $ScriptBlock -Previous $PreviouslyGeneratedTests
        # }

        $test = New-TestObject -Name $Name -ScriptBlock $ScriptBlock -Tag $Tag -Data $Data -Id $Id -Path $path -Focus:$Focus -Skip:$Skip
        $test.FrameworkData.Runtime.Phase = 'Discovery'

        Add-Test -Test $test
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope DiscoveryCore "Added test '$Name'"
        }
    }
    finally {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Leaving path $($path -join '.')"
        }
        $state.CurrentTest = $null
        $null = Pop-Scope
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Left test $Name"
        }

        # keep this at the end so we report even the test teardown in the framework overhead for the test
        $test.Duration = $state.UserCodeStopWatch.Elapsed - $testStartTime
        $test.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Timing -Message "Test duration $($test.Duration.TotalMilliseconds)ms"
            Write-PesterDebugMessage -Scope Timing -Message "Framework duration $($test.FrameworkDuration.TotalMilliseconds)ms"
        }
    }
}

function Invoke-TestItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Test
    )
    # keep this at the top so we report as much time
    # of the actual test run as possible
    $overheadStartTime = $state.FrameworkStopWatch.Elapsed
    $testStartTime = $state.UserCodeStopWatch.Elapsed
    Switch-Timer -Scope Framework

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Entering test $($Test.Name)"
    }

    try {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Entering path $($Test.Path -join '.')"
        }

        $Test.FrameworkData.Runtime.Phase = 'Execution'
        Set-CurrentTest -Test $Test

        if (-not $Test.ShouldRun) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope Runtime "Test is excluded from run, returning"
            }
            return
        }

        $Test.ExecutedAt = [DateTime]::Now
        $Test.Executed = $true

        $Test.ExpandedName = & $state.ExpandName -Name $Test.Name -Data $Test.Data

        $block = $Test.Block
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Running test '$($Test.Name)'."
        }

        # no callbacks are provided because we are not transitioning between any states
        $frameworkSetupResult = Invoke-ScriptBlock `
            -OuterSetup @(
            if ($Test.First) { selectNonNull $state.Plugin.OneTimeTestSetupStart }
        ) `
            -Setup @( selectNonNull $state.Plugin.EachTestSetupStart ) `
            -ScriptBlock { } `
            -Context @{
            Context = @{
                # context visible to Plugins
                Block         = $block
                Test          = $Test
                Configuration = $state.PluginConfiguration
            }
        }

        if ($Test.Skip) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                $path = $Test.Path -join '.'
                Write-PesterDebugMessage -Scope RuntimeSkip "($path) Test is skipped."
            }

            # setting the test as passed here, this is by choice
            # skipped test are ultimately passed tests that were not executed
            # I expect that if someone works with the raw result object and
            # filters on .Passed -eq $false they should get the count of failed tests
            # not failed + skipped. It might be wise to revert those booleans to "enum"
            # because they are exclusive, but keeping the info in the object stupid
            # and aggregating it as needed was also a design choice
            $Test.Passed = $true
            $Test.Skipped = $true
            $Test.FrameworkData.Runtime.ExecutionStep = 'Finished'
        }
        else {

            if ($frameworkSetupResult.Success) {
                try  {
                    $testInfo = @(foreach ($t in $Test) { [PSCustomObject]@{ Name = $t.Name; Path = $t.Path }})
                } catch
                {
                    throw $_;
                }

                # TODO: use PesterContext as the name, or some other better reserved name to avoid conflicts
                $context = @{
                    # context visible in test
                    Context = $testInfo
                }
                # user provided data are merged with Pester provided context
                Merge-Hashtable -Source $Test.Data -Destination $context

                $eachTestSetups = CombineNonNull (Recurse-Up $Block { param ($b) $b.EachTestSetup } )
                $eachTestTeardowns = CombineNonNull (Recurse-Up $Block { param ($b) $b.EachTestTeardown } )

                $result = Invoke-ScriptBlock `
                    -Setup @(
                    if (any $eachTestSetups) {
                        # we collect the child first but want the parent to run first
                        [Array]::Reverse($eachTestSetups)
                        @( { $Test.FrameworkData.Runtime.ExecutionStep = 'EachTestSetup' }) + @($eachTestSetups)
                    }
                    # setting the execution info here so I don't have to invoke change the
                    # contract of Invoke-ScriptBlock to accept multiple -ScriptBlock, because
                    # that is not needed, and would complicate figuring out in which session
                    # state we should run.
                    # this should run every time.
                    { $Test.FrameworkData.Runtime.ExecutionStep = 'Test' }
                ) `
                    -ScriptBlock $Test.ScriptBlock `
                    -Teardown @(
                    if (any $eachTestTeardowns) {
                        @( { $Test.FrameworkData.Runtime.ExecutionStep = 'EachTestTeardown' }) + @($eachTestTeardowns)
                    } ) `
                    -Context $context `
                    -ReduceContextToInnerScope `
                    -MoveBetweenScopes `
                    -OnUserScopeTransition { Switch-Timer -Scope UserCode } `
                    -OnFrameworkScopeTransition { Switch-Timer -Scope Framework } `
                    -NoNewScope `
                    -Configuration $state.Configuration

                $Test.FrameworkData.Runtime.ExecutionStep = 'Finished'
                $Test.Passed = $result.Success
                $Test.StandardOutput = $result.StandardOutput
                $Test.ErrorRecord = $result.ErrorRecord
            }
        }


        # setting those values here so they are available for the teardown
        # BUT they are then set again at the end of the block to make them accurate
        # so the value on the screen vs the value in the object is slightly different
        # with the value in the result being the correct one
        $Test.Duration = $state.UserCodeStopWatch.Elapsed - $testStartTime
        $Test.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime

        $frameworkEachTestTeardowns = @( selectNonNull $state.Plugin.EachTestTeardownEnd )
        $frameworkOneTimeTestTeardowns = @(if ($Test.Last) { selectNonNull $state.Plugin.OneTimeTestTeardownEnd })
        [array]::Reverse($frameworkEachTestTeardowns)
        [array]::Reverse($frameworkOneTimeTestTeardowns)

        $frameworkTeardownResult = Invoke-ScriptBlock `
            -ScriptBlock { } `
            -Teardown $frameworkEachTestTeardowns `
            -OuterTeardown $frameworkOneTimeTestTeardowns `
            -Context @{
            Context = @{
                # context visible to Plugins
                Test          = $Test
                Block         = $block
                Configuration = $state.PluginConfiguration
            }
        }

        if (-not $frameworkTeardownResult.Success -or -not $frameworkTeardownResult.Success) {
            throw $frameworkTeardownResult.ErrorRecord[-1]
        }

    }
    finally {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Leaving path $($Test.Path -join '.')"
        }
        $state.CurrentTest = $null
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Left test $($Test.Name)"
        }

        # keep this at the end so we report even the test teardown in the framework overhead for the test
        $Test.Duration = $state.UserCodeStopWatch.Elapsed - $testStartTime
        $Test.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Timing -Message "Test duration $($Test.Duration.TotalMilliseconds)ms"
            Write-PesterDebugMessage -Scope Timing -Message "Framework duration $($Test.FrameworkDuration.TotalMilliseconds)ms"
        }
    }
}

function Get-Id {
    param (
        [Parameter(Mandatory)]
        $Previous,
        [Parameter(Mandatory)]
        [ScriptBlock] $ScriptBlock
    )

    # give every test or block implicit id (position), so when we generate and run
    # them from foreach we can pair them together, even though they are
    # on the same position in the file
    $currentLocation = $ScriptBlock.StartPosition.StartLine

    if (-not $Previous.ContainsKey($currentLocation)) {
        $previousItem = New-PreviousItemObject
        $Previous.Add($currentLocation, $previousItem)
    }
    else {
        $previousItem = $previous.$currentLocation
    }

    if (-not $previousItem.Any) {
        0
    }
    else {
        if ($previousItem.Location -eq $currentLocation) {
            $position = ++$previousItem.Counter
            [string] $position
        }
    }

    $previousItem.Any = $true
    # counter is mutated in place above
    # $previousItem.Counter
    $previousItem.Location = $currentLocation
    $previousItem.Name = $Name
}

# endpoint for adding a setup for each test in the block
function New-EachTestSetup {
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )

    if (Is-Discovery) {
        (Get-CurrentBlock).EachTestSetup = $ScriptBlock
    }
}

# endpoint for adding a teardown for each test in the block
function New-EachTestTeardown {
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )

    if (Is-Discovery) {
        (Get-CurrentBlock).EachTestTeardown = $ScriptBlock
    }
}

# endpoint for adding a setup for all tests in the block
function New-OneTimeTestSetup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )

    if (Is-Discovery) {
        (Get-CurrentBlock).OneTimeTestSetup = $ScriptBlock
    }
}

# endpoint for adding a teardown for all tests in the block
function New-OneTimeTestTeardown {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )
    if (Is-Discovery) {
        (Get-CurrentBlock).OneTimeTestTeardown = $ScriptBlock
    }
}

# endpoint for adding a setup for each block in the current block
function New-EachBlockSetup {
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )
    if (Is-Discovery) {
        (Get-CurrentBlock).EachBlockSetup = $ScriptBlock
    }
}

# endpoint for adding a teardown for each block in the current block
function New-EachBlockTeardown {
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )
    if (Is-Discovery) {
        (Get-CurrentBlock).EachBlockTeardown = $ScriptBlock
    }
}

# endpoint for adding a setup for all blocks in the current block
function New-OneTimeBlockSetup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )
    if (Is-Discovery) {
        (Get-CurrentBlock).OneTimeBlockSetup = $ScriptBlock
    }
}

# endpoint for adding a teardown for all clocks in the current block
function New-OneTimeBlockTeardown {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )
    if (Is-Discovery) {
        (Get-CurrentBlock).OneTimeBlockTeardown = $ScriptBlock
    }
}

function Get-CurrentBlock {
    [CmdletBinding()]
    param()

    Assert-InvokedNonInteractively

    $state.CurrentBlock
}

function Get-CurrentTest {
    [CmdletBinding()]
    param()

    Assert-InvokedNonInteractively

    $state.CurrentTest
}

function Set-CurrentBlock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Block
    )

    $state.CurrentBlock = $Block
}


function Set-CurrentTest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Test
    )

    $state.CurrentTest = $Test
}

function Add-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredTest")]
        $Test
    )
    $block = Get-CurrentBlock
    $block.Tests.Add($Test)
    $block.Order.Add($Test)
}

function New-TestObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Name,
        [String[]] $Path,
        [String[]] $Tag,
        [System.Collections.IDictionary] $Data,
        [String] $Id,
        [ScriptBlock] $ScriptBlock,
        [Switch] $Focus,
        [Switch] $Skip
    )

    New_PSObject -Type DiscoveredTest @{
        ItemType          = 'Test'
        Id                = $Id
        ScriptBlock       = $ScriptBlock
        Name              = $Name
        Path              = $Path
        Tag               = $Tag
        Focus             = [Bool]$Focus
        Skip              = [Bool]$Skip
        Data              = $Data

        ExpandedName      = $null
        Block             = $null

        First             = $false
        Last              = $false
        Include           = $false
        Exclude           = $false
        Explicit          = $false
        ShouldRun         = $false

        Executed          = $false
        ExecutedAt        = $null
        Passed            = $false
        Skipped           = $false
        StandardOutput    = $null
        ErrorRecord       = [Collections.Generic.List[Object]]@()

        Duration          = [timespan]::Zero
        FrameworkDuration = [timespan]::Zero
        PluginData        = @{ }
        FrameworkData     = @{
            Runtime = @{
                Phase         = $null
                ExecutionStep = $null
            }
        }
    }
}

function New-BlockObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Name,
        [string[]] $Path,
        [string[]] $Tag,
        [ScriptBlock] $ScriptBlock,
        [HashTable] $FrameworkData = @{ },
        [HashTable] $PluginData = @{ },
        [Switch] $Focus,
        [String] $Id,
        [Switch] $Skip
    )

    New_PSObject -Type DiscoveredBlock @{
        ItemType               = 'Block'
        Id                   = $Id
        Name                 = $Name
        Path                 = $Path
        Tag                  = $Tag
        ScriptBlock          = $ScriptBlock
        FrameworkData        = $FrameworkData
        PluginData           = $PluginData
        Focus                = [bool] $Focus
        Skip                 = [bool] $Skip

        Tests                = [Collections.Generic.List[Object]]@()
        # TODO: consider renaming this to just Container
        BlockContainer       = $null
        Root                 = $null
        IsRoot               = $null
        Parent               = $null
        EachTestSetup        = $null
        OneTimeTestSetup     = $null
        EachTestTeardown     = $null
        OneTimeTestTeardown  = $null
        EachBlockSetup       = $null
        OneTimeBlockSetup    = $null
        EachBlockTeardown    = $null
        OneTimeBlockTeardown = $null
        Order                = [Collections.Generic.List[Object]]@()
        Blocks               = [Collections.Generic.List[Object]]@()
        Executed             = $false
        Passed               = $false
        First                = $false
        Last                 = $false
        StandardOutput       = $null
        ErrorRecord          = [Collections.Generic.List[Object]]@()
        ShouldRun            = $false
        Exclude              = $false
        Include              = $false
        Explicit             = $false
        ExecutedAt           = $null
        Duration             = [timespan]::Zero
        FrameworkDuration    = [timespan]::Zero
        OwnDuration          = [timespan]::Zero
        DiscoveryDuration    = [timespan]::Zero
        OwnPassed     = $false
        TotalCount = 0
        PassedCount = 0
        FailedCount = 0
        SkippedCount = 0
        PendingCount = 0
        NotRunCount = 0
        InconclusiveCount = 0
        OwnTotalCount = 0
        OwnPassedCount = 0
        OwnFailedCount = 0
        OwnSkippedCount = 0
        OwnPendingCount = 0
        OwnNotRunCount = 0
        OwnInconclusiveCount = 0
    }
}

function Add-Block {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")]
        $Block
    )

    $currentBlock = (Get-CurrentBlock)
    $Block.Parent = $currentBlock
    $currentBlock.Order.Add($Block)
    $currentBlock.Blocks.Add($Block)
}

function Is-Discovery {
    $state.Discovery
}

function Discover-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("BlockContainer")][PSObject[]] $BlockContainer,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState,
        $Filter
    )
    $totalDiscoveryDuration = [Diagnostics.Stopwatch]::StartNew()

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Discovery -Message "Starting test discovery in $(@($BlockContainer).Length) test containers."
    }

    Invoke-PluginStep -Plugins $state.Plugin -Step DiscoveryStart -Context @{
        BlockContainers = $BlockContainer
        Configuration = $state.PluginConfiguration
    } -ThrowOnFailure

    $state.Discovery = $true
    $found = foreach ($container in $BlockContainer) {
        $perContainerDiscoveryDuration = [Diagnostics.Stopwatch]::StartNew()

        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Discovery "Discovering tests in $($container.Content)"
        }

        # this is a block object that we add so we can capture
        # OneTime* and Each* setups, and capture multiple blocks in a
        # container
        $root = New-BlockObject -Name "Root" -Path "Root"
        $root.First = $true
        $root.Last = $true

        Reset-PerContainerState -RootBlock $root

        Invoke-PluginStep -Plugins $state.Plugin -Step ContainerDiscoveryStart -Context @{
            BlockContainer = $container
            Configuration = $state.PluginConfiguration
        } -ThrowOnFailure

        $null = Invoke-BlockContainer -BlockContainer $container -SessionState $SessionState

        [PSCustomObject]@{
            Container = $container
            Block     = $root
        }

        Invoke-PluginStep -Plugins $state.Plugin -Step ContainerDiscoveryEnd -Context @{
            BlockContainer = $container
            Block          = $root
            Duration       = $perContainerDiscoveryDuration.Elapsed
            Configuration = $state.PluginConfiguration
        } -ThrowOnFailure

        $root.DiscoveryDuration = $perContainerDiscoveryDuration.Elapsed
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Discovery -LazyMessage { "Found $(@(View-Flat -Block $root).Count) tests" }
            Write-PesterDebugMessage -Scope DiscoveryCore "Discovery done in this container."
        }
    }

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Discovery "Processing discovery result objects, to set root, parents, filters etc."
    }

    # if any tests / block in the suite have -Focus parameter then all filters are disregarded
    # and only those tests / blocks should run
    $focusedTests = [System.Collections.Generic.List[Object]]@()
    foreach ($f in $found) {
        Fold-Container -Container $f.Block `
            -OnTest {
                # add all focused tests
                param($t)
                if ($t.Focus) {
                    $focusedTests.Add("$(if($null -ne $t.ScriptBlock.File) { $t.ScriptBlock.File } else { $t.ScriptBlock.Id }):$($t.ScriptBlock.StartPosition.StartLine)")
                }
            } `
            -OnBlock {
                param($b) if ($b.Focus) {
                    # add all tests in the current block, no matter if they are focused or not
                    Fold-Block -Block $b -OnTest {
                        param ($t)
                        $focusedTests.Add("$(if($null -ne $t.ScriptBlock.File) { $t.ScriptBlock.File } else { $t.ScriptBlock.Id }):$($t.ScriptBlock.StartPosition.StartLine)")
                    }
                }
            }
    }

    if ($focusedTests.Count -gt 0) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Discovery  -LazyMessage { "There are some ($($focusedTests.Count)) focused tests '$($(foreach ($p in $focusedTests) { $p -join "." }) -join ",")' running just them." }
        }
        $Filter =  New-FilterObject -Line $focusedTests
    }

    foreach ($f in $found) {
        # this takes non-trivial time, measure how long it takes and add it to the discovery
        # so we get more accurate total time
        $overhead = Measure-Command {
            PostProcess-DiscoveredBlock -Block $f.Block -Filter $Filter -BlockContainer $f.Container -RootBlock $f.Block
        }
        $f.Block.DiscoveryDuration += $overhead
        $f.Block
    }

    Invoke-PluginStep -Plugins $state.Plugin -Step DiscoveryEnd -Context @{
        BlockContainers = $found.Block
        AnyFocusedTests = $focusedTests.Count -gt 0
        FocusedTests    = $focusedTests
        Duration        = $totalDiscoveryDuration.Elapsed
        Configuration = $state.PluginConfiguration
    } -ThrowOnFailure

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Discovery "Test discovery finished."
    }
}

function Run-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")][PSObject[]] $Block,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState
    )

    $state.Discovery = $false
    foreach ($rootBlock in $Block) {
        $blockStartTime = $state.UserCodeStopWatch.Elapsed
        $overheadStartTime = $state.FrameworkStopWatch.Elapsed
        Switch-Timer -Scope Framework

        if (-not $rootBlock.ShouldRun) {
            ConvertTo-ExecutedBlockContainer -Block $rootBlock
            continue
        }
        # this resets the timers so keep that before measuring the time
        Reset-PerContainerState -RootBlock $rootBlock

        $rootBlock.Executed = $true
        $rootBlock.ExecutedAt = [DateTime]::now

        Invoke-PluginStep -Plugins $state.Plugin -Step ContainerRunStart -Context @{
            Block = $rootBlock
            Configuration = $state.PluginConfiguration
        } -ThrowOnFailure

        try {
            # if ($null -ne $rootBlock.OneTimeBlockSetup) {
            #    throw "One time block setup is not supported in root (directly in the block container)."
            #}

            # if ($null -ne $rootBlock.EachBlockSetup) {
            #     throw "Each block setup is not supported in root (directly in the block container)."
            # }

            if ($null -ne $rootBlock.EachTestSetup) {
                throw "Each test setup is not supported in root (directly in the block container)."
            }

            if (
                $null -ne $rootBlock.EachTestTeardown `
                    -or $null -ne $rootBlock.OneTimeTestTeardown #`
                #-or $null -ne $rootBlock.OneTimeBlockTeardown `
                #-or $null -ne $rootBlock.EachBlockTeardown `
            ) {
                throw "Teardowns are not supported in root (directly in the block container)."
            }

            $rootSetupResult = $null
            if ($null -ne $rootBlock.OneTimeTestSetup) {
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    Write-PesterDebugMessage -Scope Runtime "One time setup from root block is executing"
                }

                $rootSetupResult = Invoke-ScriptBlock `
                    -OuterSetup @(
                    # if ($rootBlock.ShouldRun) {
                        # todo: should this always run?
                        selectNonNull $rootBlock.OneTimeTestSetup
                    # }
                ) `
                    -Setup @() `
                    -ScriptBlock { } `
                    -Context @{ } `
                    -ReduceContextToInnerScope `
                    -MoveBetweenScopes `
                    -OnUserScopeTransition { Switch-Timer -Scope UserCode } `
                    -OnFrameworkScopeTransition { Switch-Timer -Scope Framework }
            }


            if ($null -ne $rootSetupResult -and -not $rootSetupResult.Success) {
                & $SafeCommands["Write-Error"] -ErrorRecord $rootSetupResult.ErrorRecord[0] -ErrorAction 'Stop'
            }

            $null = Invoke-Block -previousBlock $rootBlock

            $rootBlock.OwnPassed = $true
        }
        catch {
            $rootBlock.OwnPassed = $false
            $rootBlock.ErrorRecord.Add($_)
        }

        PostProcess-ExecutedBlock -Block $rootBlock
        $result = ConvertTo-ExecutedBlockContainer -Block $rootBlock
        $result.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
        $result.Duration = $state.UserCodeStopWatch.Elapsed - $blockStartTime

        Invoke-PluginStep -Plugins $state.Plugin -Step ContainerRunEnd -Context @{
            Result = $result
            Block  = $rootBlock
            Configuration = $state.PluginConfiguration
        } -ThrowOnFailure

        # set this again so the plugins have some data but that we also include the plugin invocation to the
        # overall time to keep the actual timing correct
        $result.FrameworkDuration = $state.FrameworkStopWatch.Elapsed - $overheadStartTime
        $result.Duration = $state.UserCodeStopWatch.Elapsed - $blockStartTime
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Timing "Container duration $($result.Duration.TotalMilliseconds)ms"
            Write-PesterDebugMessage -Scope Timing "Container framework duration $($result.FrameworkDuration.TotalMilliseconds)ms"
        }

        $result
    }
}

function Invoke-PluginStep {
    [CmdletBinding()]
    param (
        [PSObject[]] $Plugins,
        [Parameter(Mandatory)]
        [ValidateSet('Start', 'DiscoveryStart', 'ContainerDiscoveryStart', 'BlockDiscoveryStart', 'TestDiscoveryStart', 'TestDiscoveryEnd', 'BlockDiscoveryEnd', 'ContainerDiscoveryEnd', 'DiscoveryEnd', 'RunStart', 'ContainerRunStart', 'OneTimeBlockSetupStart', 'EachBlockSetupStart', 'OneTimeTestSetupStart', 'EachTestSetupStart', 'EachTestTeardownEnd', 'OneTimeTestTeardownEnd', 'EachBlockTeardownEnd', 'OneTimeBlockTeardownEnd', 'ContainerRunEnd', 'RunEnd', 'End')]
        [String] $Step,
        $Context = @{ },
        [Switch] $ThrowOnFailure
    )

    # there are actually two ways to invoke plugin steps, this unified cmdlet that allows us to run the steps
    # in isolation, and then another where we are using Invoke-ScriptBlock directly when we need the plugin to run
    # for example as a teardown step of a test.

    Switch-Timer -Scope Framework
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
    }

    # this is end step, we should run all steps no matter if some failed, and we should run them in opposite direction
    $isEndStep = $Step -like "*End"

    $pluginsWithGivenStep =
    @(foreach ($p in $Plugins) {
            if ($p."Has$Step") {
                $p
            }
        })


    if ($null -eq $pluginsWithGivenStep -or 0 -eq @($pluginsWithGivenStep).Count) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope PluginCore "No plugins with step $Step were provided"
        }
        return
    }

    if (-not $isEndStep) {
        [Array]::Reverse($pluginsWithGivenStep)
    }

    $err = [Collections.Generic.List[Management.Automation.ErrorRecord]]@()
    $failed = $false
    $standardOutput =
    foreach ($p in $pluginsWithGivenStep) {
        if ($failed -and -not $isEndStep) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope Plugin "Skipping $($p.Name) step $Step because some previous plugin failed"
            }
            continue
        }

        try {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                $stepSw = [Diagnostics.Stopwatch]::StartNew()
                Write-PesterDebugMessage -Scope Plugin "Running $($p.Name) step $Step with context '$($Context | Out-String)'"
            }

            # the plugins expect -Context and then the actual context in it
            # this was a choice at the start of the project to make it easy to see
            # what is available, not sure if a good choice
            $ctx = @{
                Context = $Context
            }
            do {
                & $p.$Step @ctx
            } while ($false)

            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope Plugin "Success $($p.Name) step $Step in $($stepSw.ElapsedMilliseconds) ms"
            }
        }
        catch {
            $failed = $true
            $err.Add($_)
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope Plugin "Failed $($p.Name) step $Step in $($stepSw.ElapsedMilliseconds) ms" -ErrorRecord $_
            }
        }
    }

    $r = New-InvocationResultObject -Success (-not $failed) -ErrorRecord $err -StandardOutput $standardOutput


    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Plugin "Invoking plugins in step $Step took $($sw.ElapsedMilliseconds) ms"
    }
    if ($ThrowOnFailure) {
        Assert-Success $r -Message "Invoking step $step failed"
    }
    else {
        return $r
    }
}

function Assert-Success {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PStypeName("InvocationResult")][PSObject[]] $InvocationResult,
        [String] $Message = "Invocation failed"
    )

    $rc = 0
    $anyFailed = $false
    foreach ($r in $InvocationResult) {
        $ec = 0
        if ($null -ne $r.ErrorRecord -and $r.ErrorRecord.Length -gt 0) {
            & $SafeCommands["Write-Host"] -ForegroundColor Red "Result $($rc++):"
            $anyFailed = $true
            foreach ($e in $r.ErrorRecord) {
                & $SafeCommands["Write-Host"] -ForegroundColor Red "Error $($ec++):"
                & $SafeCommands["Write-Host"] -ForegroundColor Red (Out-String -InputObject $e )
                & $SafeCommands["Write-Host"] -ForegroundColor Red (Out-String -InputObject $e.ScriptStackTrace)
            }
        }

        if ($anyFailed) {
            throw $Message
        }
    }
}

function Invoke-ScriptBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock] $ScriptBlock,
        [ScriptBlock[]] $OuterSetup,
        [ScriptBlock[]] $Setup,
        [ScriptBlock[]] $Teardown,
        [ScriptBlock[]] $OuterTeardown,
        $Context = @{ },
        # define data to be shared in only in the inner scope where e.g eachTestSetup + test run but not
        # in the scope where OneTimeTestSetup runs, on the other hand, plugins want context
        # in all scopes
        [Switch] $ReduceContextToInnerScope,
        # # setup, body and teardown will all run (be-dotsourced into)
        # # the same scope
        # [Switch] $SameScope,
        # will dot-source the wrapper scriptblock instead of invoking it
        # so in combination with the SameScope switch we are effectively
        # running the code in the current scope
        [Switch] $NoNewScope,
        [Switch] $MoveBetweenScopes,
        [ScriptBlock] $OnUserScopeTransition = { },
        [ScriptBlock] $OnFrameworkScopeTransition = { },
        $Configuration
    )

    # this is what the code below does
    # . $OuterSetup
    # & {
    #     try {
    #       # import setup to scope
    #       . $Setup
    #       # executed the test code in the same scope
    #       . $ScriptBlock
    #     } finally {
    #       . $Teardown
    #     }
    # }
    # . $OuterTeardown


    $wrapperScriptBlock = {
        # THIS RUNS (MOST OF THE TIME) IN USER SCOPE, BE CAREFUL WHAT YOU PUBLISH AND CONSUME!
        param($______parameters)

        try {
             if ($______parameters.ContextInOuterScope) {
                $______outerSplat = $______parameters.Context
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Setting context variables" }
                foreach ($______current in $______outerSplat.GetEnumerator()) {
                    if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Setting context variable '$($______current.Key)' with value '$($______current.Value)'" }
                    $ExecutionContext.SessionState.PSVariable.Set($______current.Key, $______current.Value)
                }
                $______current = $null
            }
            else {
                $______outerSplat = @{ }
            }

            if ($null -ne $______parameters.OuterSetup -and $______parameters.OuterSetup.Length -gt 0) {
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running outer setups" }
                foreach ($______current in $______parameters.OuterSetup) {
                    if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running outer setup { $______current }" }
                    $______parameters.CurrentlyExecutingScriptBlock = $______current
                    . $______current @______outerSplat
                }
                $______current = $null
                $______parameters.OuterSetup = $null
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running outer setups" }
            }
            else {
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "There are no outer setups" }
            }

            & {
                try {
                    # this is needed for nonewscope so we can do two different
                    # teardowns while running this code in the middle again (which rewrites the teardown
                    # value in the object), this way we save the first teardown and ressurect it right before
                    # needing it

                    # setting the value to $true, because if it was null we cannot differentiate
                    # between the variable not existing and not having value
                    $_________teardown2 = if ($null -ne $______parameters.Teardown) { $______parameters.Teardown } else { $true }

                    if (-not $______parameters.ContextInOuterScope) {
                        $______innerSplat = $______parameters.Context
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Setting context variables" }
                        foreach ($______current in $______innerSplat.GetEnumerator()) {
                            if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Setting context variable '$ ($______current.Key)' with value '$($______current.Value)'" }
                            $ExecutionContext.SessionState.PSVariable.Set($______current.Key, $______current.Value)
                        }
                        $______current = $null
                    }
                    else {
                        $______innerSplat = $______outerSplat
                    }

                    if ($null -ne $______parameters.Setup -and $______parameters.Setup.Length -gt 0) {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running inner setups" }
                        foreach ($______current in $______parameters.Setup) {
                            if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running inner setup { $______current }" }
                            $______parameters.CurrentlyExecutingScriptBlock = $______current
                            . $______current @______innerSplat
                        }
                        $______current = $null
                        $______parameters.Setup = $null
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running inner setups" }
                    }
                    else {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "There are no inner setups" }
                    }

                    if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running scriptblock { $($______parameters.ScriptBlock) }" }
                    $______parameters.CurrentlyExecutingScriptBlock = $______parameters.ScriptBlock
                    . $______parameters.ScriptBlock @______innerSplat

                    if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running scriptblock" }
                }
                catch {
                    $______parameters.ErrorRecord.Add($_)
                    if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Fail running setups or scriptblock" -ErrorRecord $_ }
                }
                finally {
                    # this is needed for nonewscope so we can do two different
                    # teardowns while running this code in the middle again (which rewrites the teardown
                    # value in the object)
                    if ($null -ne $ExecutionContext.SessionState.PSVariable.Get('_________teardown2')) {
                        # soo we are running the one time test teadown in the same scope as
                        # each block teardown and it overwrites it
                        if ($true -eq $ExecutionContext.SessionState.PSVariable.Get('_________teardown2')) {
                            # do nothing, we needed the true to detect that the property was defined
                        }
                        else {
                            $______parameters.Teardown = $_________teardown2
                        }
                        $ExecutionContext.SessionState.PSVariable.Remove('_________teardown2')
                    }

                    if ($null -ne $______parameters.Teardown -and $______parameters.Teardown.Length -gt 0) {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running inner teardowns" }
                        foreach ($______current in $______parameters.Teardown) {
                            try {
                                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running inner teardown { $______current }" }
                                $______parameters.CurrentlyExecutingScriptBlock = $______current
                                . $______current @______innerSplat
                                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running inner teardown" }
                            }
                            catch {
                                $______parameters.ErrorRecord.Add($_)
                                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Fail running inner teardown" -ErrorRecord $_ }
                            }
                        }
                        $______current = $null

                        # nulling this variable is important when we run without new scope
                        # then $______parameters.Teardown remains set and EachBlockTeardown
                        # runs twice
                        $______parameters.Teardown = $null
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running inner teardowns" }
                    }
                    else {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "There are no inner teardowns" }
                    }
                }
            }
        }
        finally {

            if ($null -ne $______parameters.OuterTeardown -and $______parameters.OuterTeardown.Length -gt 0) {
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running outer teardowns" }
                foreach ($______current in $______parameters.OuterTeardown) {
                    try {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Running outer teardown { $______current }" }
                        $______parameters.CurrentlyExecutingScriptBlock = $______current
                        . $______current @______outerSplat
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running outer teardown" }
                    }
                    catch {
                        if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Fail running outer teardown" -ErrorRecord $_ }
                        $______parameters.ErrorRecord.Add($_)
                    }
                }
                $______parameters.OuterTeardown = $null
                $______current = $null
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "Done running outer teardowns" }
            }
            else {
                if ($______parameters.EnableWriteDebug) { &$______parameters.WriteDebug "There are no outer teardowns" }
            }
        }
    }

    if ($MoveBetweenScopes) {
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $SessionState = $ScriptBlock.GetType().GetProperty("SessionState", $flags).GetValue($ScriptBlock, $null)
        $SessionStateInternal = $SessionState.GetType().GetProperty('Internal', $flags).GetValue($SessionState, $null)

        # attach the original session state to the wrapper scriptblock
        # making it invoke in the same scope as $ScriptBlock
        $wrapperScriptBlock.GetType().GetProperty('SessionStateInternal', $flags).SetValue($wrapperScriptBlock, $SessionStateInternal, $null)
    }

    #$break = $true
    $err = $null
    try {
        $parameters = @{
            ScriptBlock                   = $ScriptBlock
            OuterSetup                    = $OuterSetup
            Setup                         = $Setup
            Teardown                      = $Teardown
            OuterTeardown                 = $OuterTeardown
            CurrentlyExecutingScriptBlock = $null
            ErrorRecord                   = [Collections.Generic.List[Management.Automation.ErrorRecord]]@()
            Context                       = $Context
            ContextInOuterScope           = -not $ReduceContextToInnerScope
            EnableWriteDebug              = $PesterPreference.Debug.WriteDebugMessages.Value
            WriteDebug                    = {
                param($Message, [Management.Automation.ErrorRecord] $ErrorRecord)
                Write-PesterDebugMessage -Scope "RuntimeCore" $Message -ErrorRecord $ErrorRecord
            }
            Configuration = $Configuration
        }

        # here we are moving into the user scope if the provided
        # scriptblock was bound to user scope, so we want to take some actions
        # typically switching between user and framework timer. There are still tiny pieces of
        # framework code running in the scriptblock but we can safely ignore those becasue they are
        # just logging, so the time difference is miniscule.
        # The code might also run just in framework scope, in that case the callback can remain empty,
        # eg when we are invoking framework setup.
        if ($MoveBetweenScopes) {
            & $OnUserScopeTransition
        }
        do {
            $standardOutput = if ($NoNewScope) {
                . $wrapperScriptBlock $parameters
            }
            else {
                & $wrapperScriptBlock $parameters
            }
            # if the code reaches here we did not break
            #$break = $false
        } while ($false)
    }
    catch {
        $err = $_
    }

    if ($MoveBetweenScopes) {
        & $OnFrameworkScopeTransition
    }

    if ($err) {
        $parameters.ErrorRecord.Add($err)
    }

    $r = New-InvocationResultObject `
        -Success (0 -eq $parameters.ErrorRecord.Count) `
        -ErrorRecord $parameters.ErrorRecord `
        -StandardOutput $standardOutput

    return $r
}

function New-InvocationResultObject {
    [CmdletBinding()]
    param (
        [bool] $Success = $true,
        [Collections.Generic.List[Management.Automation.ErrorRecord]] $ErrorRecord,
        $StandardOutput
    )

    New_PSObject -Type 'InvocationResult' -Property @{
        Success        = $Success
        ErrorRecord    = $ErrorRecord
        StandardOutput = $StandardOutput
    }
}

function Merge-InvocationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSTypeName("InvocationResult")][PSObject[]] $Result
    )

    if ($Result.Count -eq 1) {
        return $Result[0]
    }

    $m = New-InvocationResultObject

    foreach ($r in $Result) {
        $m.Success = $m.Success -and $r.Success
        $null = $m.ErrorRecord.AddRange($r.ErrorRecord)
        $null = $m.StandardOutput.AddRange(@($r.StandardOutput))
    }

    $m
}


function Reset-TestSuiteTimer {
    if ($null -eq $state.TotalStopWatch) {
        $state.TotalStopWatch = [Diagnostics.Stopwatch]::StartNew()
    }

    if ($null -eq $state.UserCodeStopWatch) {
        $state.UserCodeStopWatch = [Diagnostics.Stopwatch]::StartNew()
    }

    if ($null -eq $state.FrameworkStopWatch) {
        $state.FrameworkStopWatch = [Diagnostics.Stopwatch]::StartNew()
    }

    $state.TotalStopWatch.Restart()
    $state.FrameworkStopWatch.Restart()
    $state.UserCodeStopWatch.Reset()
}

function Switch-Timer {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Framework", "UserCode")]
        $Scope
    )
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        if ($state.UserCodeStopWatch.IsRunning) {
            Write-PesterDebugMessage -Scope TimingCore "Switching from UserCode to $Scope"
        }

        if ($state.FrameworkStopWatch.IsRunning) {
            Write-PesterDebugMessage -Scope TimingCore "Switching from Framework to $Scope"
        }

        Write-PesterDebugMessage -Scope TimingCore -Message "UserCode total time $($state.UserCodeStopWatch.ElapsedMilliseconds)ms"
        Write-PesterDebugMessage -Scope TimingCore -Message "Framework total time $($state.FrameworkStopWatch.ElapsedMilliseconds)ms"
    }

    switch ($Scope) {
        "Framework" {
            # running in framework code adds time only to the overhead timer
            $state.UserCodeStopWatch.Stop()
            $state.FrameworkStopWatch.Start()
        }
        "UserCode" {
            $state.UserCodeStopWatch.Start()
            $state.FrameworkStopWatch.Stop()
        }
        default { throw [ArgumentException]"" }
    }
}

function Test-ShouldRun {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Item,
        $Filter
    )

    # see https://github.com/pester/Pester/issues/1442 for description of how this filtering works

    $result = @{
        Include = $false
        Exclude = $false
        Explicit = $false
    }

    $anyIncludeFilters = $false
    $fullDottedPath = $Item.Path -join "."
    if ($null -eq $Filter) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is included, because there is no filters."
        }

        $result.Include = $true
        return $result
    }

    $parent = if ('Test' -eq $Item.ItemType) {
        $Item.Block
    }
    elseif ('Block' -eq $Item.ItemType) {
        # no need to check if we are root, we will not run these rules on Root block
        $Item.Parent
    }

    if ($parent.Exclude) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is excluded, because it's parent is excluded."
        }
        $result.Exclude = $true
        return $result
    }

    # item is excluded when any of the exclude tags match
    $tagFilter = tryGetProperty $Filter ExcludeTag
    if (any $tagFilter) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) There is '$($tagFilter -join ", ")' exclude tag filter."
        }
        foreach ($f in $tagFilter) {
            foreach ($t in $Item.Tag) {
                if ($t -like $f) {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is excluded, because it's tag '$t' matches exclude tag filter '$f'."
                    }
                    $result.Exclude = $true
                    return $result
                }
            }
        }
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) did not match the exclude tag filter, moving on to the next filter."
        }
    }

    # - place exclude filters above this line and include below this line

    $lineFilter = tryGetProperty $Filter Line
    # use File for saved files or Id for ScriptBlocks without files
    # this filter has the ability to set the test to "explicit" so we can run
    # the test even if it is marked as skipped run this include as first so we figure it out
    # in one place and check if parent was included after this one to short circuit the other
    # filters in case parent already knows that it will run
    $line = "$(if ($Item.ScriptBlock.File) { $Item.ScriptBlock.File } else { $Item.ScriptBlock.Id }):$($Item.ScriptBlock.StartPosition.StartLine)" -replace '\\','/'
    if (any $lineFilter) {
        $anyIncludeFilters = $true
        foreach ($l in $lineFilter -replace '\\','/') {
            if ($l -eq $line) {
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is included, because its path:line '$line' matches line filter '$lineFilter'."
                }

               # if ('Test' -eq $Item.ItemType ) {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is explicitly included, because it matched line filter, and will run even if -Skip is specified on it. Any skipped children will still be skipped."
                    }

                    $result.Explicit = $true
                # }

                $result.Include = $true
                return $result
            }
        }
    }

    if ($parent.Include) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is included, because its parent is included."
        }

        $result.Include = $true
        return $result
    }

    # test is included when it has tags and the any of the tags match
    $tagFilter = tryGetProperty $Filter Tag
    if (any $tagFilter) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) There is '$($tagFilter -join ", ")' include tag filter."
        }
        $anyIncludeFilters = $true
        if (none $Item.Tag) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) has no tags, moving to next include filter."
            }
        }
        else {
            foreach ($f in $tagFilter) {
                foreach ($t in $Item.Tag) {
                    if ($t -like $f) {
                        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                            Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is included, because it's tag '$t' matches tag filter '$f'."
                        }

                        $result.Include = $true
                        return $result
                    }
                }
            }
        }
    }

    $allPaths = foreach ($p in @(tryGetProperty $Filter Path)) { $p -join '.' }
    if (any $allPaths) {
        $anyIncludeFilters = $true
        $include = $allPaths -contains $fullDottedPath
        if ($include) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) is included, because it matches full path filter."
            }

            $result.Include = $true
            return $result
        }
        else {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) does not match the dotted path filter, moving to next include filter."
            }
        }
    }

    if ($anyIncludeFilters) {
        if ('Test' -eq $Item.ItemType) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) did not match any of the include filters, it will not be included in the run."
            }
        }
        elseif ('Block' -eq $Item.ItemType) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) did not match any of the include filters, but it will still be included in the run, it's children will determine if it will run."
            }
        }
        else  {
            throw "Item type $($Item.ItemType) is not supported in filter."
        }
    }
    else {
        if ('Test' -eq $Item.ItemType) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) will be included in the run, because there were no include filters so all tests are included unless they match exclude rule."
            }

            $result.Include = $true
        }
        elseif ('Block' -eq $Item.ItemType) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeFilter "($fullDottedPath) $($Item.ItemType) will be included in the run, because there were no include filters, and will let its children to determine whether or not it should run."
            }
        }
        else  {
            throw "Item type $($Item.ItemType) is not supported in filter."
        }

        return $result
    }

    return $result
}

function Invoke-Test {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSTypeName("BlockContainer")][PSObject[]] $BlockContainer,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState,
        $Filter,
        $Plugin,
        $PluginConfiguration,
        $Configuration
    )

    # set the incoming value for all the child scopes
    # TODO: revisit this because this will probably act weird as we jump between session states
    $PesterPreference = $Configuration

    # don't scope InvokedNonInteractively to script we want the functions
    # that are called by this to see the value but it should not be
    # persisted afterwards so we don't have to reset it to $false
    $InvokedNonInteractively = $true

    $state.Plugin = $Plugin
    $state.PluginConfiguration = $PluginConfiguration
    $state.Configuration = $Configuration

    # # TODO: this it potentially unreliable, because supressed errors are written to Error as well. And the errors are captured only from the caller state. So let's use it only as a useful indicator during migration and see how it works in production code.

    # # finding if there were any non-terminating errors during the run, user can clear the array, and the array has fixed size so we can't just try to detect if there is any difference by counts before and after. So I capture the last known error in that state and try to find it in the array after the run
    # $originalErrors = $SessionState.PSVariable.Get("Error").Value
    # $originalLastError = $originalErrors[0]
    # $originalErrorCount = $originalErrors.Count

    $found = Discover-Test -BlockContainer $BlockContainer -Filter $Filter -SessionState $SessionState

    # $errs = $SessionState.PSVariable.Get("Error").Value
    # $errsCount = $errs.Count
    # if ($errsCount -lt $originalErrorCount) {
    #     # it would be possible to detect that there are 0 errors, in the array and continue,
    #     # but this still indicates the user code is running where it should not, so let's throw anyway
    #     throw "Test discovery failed. The error count ($errsCount) after running discovery is lower than the error count before discovery ($originalErrorCount). Is some of your code running outside Pester controlled blocks and it clears the `$error array by calling `$error.Clear()?"

    # }


    # if ($originalErrorCount -lt $errsCount) {
    #     # probably the most usual case,  there are more errors then there were before,
    #     # so some were written to the screen, this also runs when the user cleared the
    #     # array and wrote more errors than there originally were
    #     $i = $errsCount - $originalErrorCount
    # }
    # else {
    #     # there is equal amount of errors, the array was probably full and so the original
    #     # error shifted towards the end of the array, we try to find it and see how many new
    #     # errors are there
    #     for ($i = 0 ; $i -lt $errsLength; $i++) {
    #         if ([object]::referenceEquals($errs[$i], $lastError)) {
    #             break
    #         }
    #     }
    # }
    # if (0 -ne $i) {
    #     throw "Test discovery failed. There were $i non-terminating errors during test discovery. This indicates that some of your code is invoked outside of Pester controlled blocks and fails. No tests will be run."
    # }
    Run-Test -Block $found -SessionState $SessionState
}

function PostProcess-DiscoveredBlock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName("DiscoveredBlock")][PSObject] $Block,
        [PSTypeName("Filter")] $Filter,
        [PSTypeName("BlockContainer")] $BlockContainer,
        [Parameter(Mandatory = $true)]
        [PSTypeName("DiscoveredBlock")][PSObject] $RootBlock
    )

    # TODO: this whole code is quite slow, make it faster

    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        $path = $Block.Path -join "."
    }

    # traverses the block structure after a block was found and
    # link childs to their parents, filter blocks and tests to
    # determine which should run, and mark blocks and tests
    # as first or last to know when one time setups & teardowns should run
    $Block.IsRoot = $Block -eq $RootBlock
    $Block.Root = $RootBlock
    $Block.BlockContainer = $BlockContainer
    $Block.FrameworkData.PreviouslyGeneratedTests = @{ }
    $Block.FrameworkData.PreviouslyGeneratedBlocks = @{ }

    $tests = $Block.Tests

    if ($Block.IsRoot) {
        $Block.Explicit = $false
        $Block.Exclude = $false
        $Block.Include = $false
        $Block.ShouldRun = $true
    }
    else {
        $shouldRun = (Test-ShouldRun -Item $Block -Filter $Filter)
        $Block.Explicit = $shouldRun.Explicit

        if (-not $shouldRun.Exclude -and -not $shouldRun.Include) {
            $Block.ShouldRun = $true
        }
        elseif ($shouldRun.Include) {
            $Block.ShouldRun = $true
        }
        elseif ($shouldRun.Exclude) {
            $Block.ShouldRun = $false
        }
        else {
            throw "Unknown combination of include exclude $($shouldRun)"
        }

        $Block.Include = $shouldRun.Include -and -not $shouldRun.Exclude
        $Block.Exclude = $shouldRun.Exclude
    }

    $parentBlockIsSkipped = (-not $Block.IsRoot -and $Block.Parent.Skip)

    if ($Block.Skip) {
        if ($Block.Explicit) {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeSkip "($path) Block was marked as skipped, but will not be skipped because it was explicitly requested to run."
            }

            $Block.Skip = $false
        }
        else {
            if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                Write-PesterDebugMessage -Scope RuntimeSkip "($path) Block is skipped."
            }

            $Block.Skip = $true
        }
    }
    elseif ($parentBlockIsSkipped) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeSkip "($path) Block is skipped because a parent block was skipped."
        }

        $Block.Skip = $true
    }

    $blockShouldRun = $false
    if ($tests.Count -gt 0) {
        foreach ($t in $tests) {
            $t.Block = $Block

            if ($t.Block.Exclude) {
                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    $path = $t.Path -join "."
                    Write-PesterDebugMessage -Scope RuntimeFilter "($path) Test is excluded because parent block was excluded."
                }
                $t.ShouldRun = $false
            }
            else {
                # run the exlude filters before checking if the parent is included
                # otherwise you would include tests that could match the exclude rule
                $shouldRun = (Test-ShouldRun -Item $t -Filter $Filter)
                $t.Explicit = $shouldRun.Explicit

                if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                    $path = $t.Path -join "."
                }

                if (-not $shouldRun.Include -and -not $shouldRun.Exclude) {
                    $t.ShouldRun = $false
                }
                elseif ($shouldRun.Include) {
                    $t.ShouldRun = $true
                }
                elseif ($shouldRun.Exclude) {
                    $t.ShouldRun = $false
                }
                else {
                    throw "Unknown combination of ShouldRun $ShouldRun"
                }
            }

            if ($t.Skip) {
                if ($t.ShouldRun -and $t.Explicit) {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeSkip "($path) Test was marked as skipped, but will not be skipped because it was explicitly requested to run."
                    }

                    $t.Skip = $false
                }
                else {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeSkip "($path) Test is skipped."
                    }

                    $t.Skip = $true
                }
            }
            elseif ($Block.Skip) {
                if ($t.ShouldRun -and $t.Explicit) {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeSkip "($path) Test was marked as skipped, because its parent was marked as skipped, but will not be skipped because it was explicitly requested to run."
                    }

                    $t.Skip = $false
                }
                else {
                    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
                        Write-PesterDebugMessage -Scope RuntimeSkip "($path) Test is skipped because a parent block was skipped."
                    }

                    $t.Skip = $true
                }
            }
        }


        # if we determined that the block should run we can still make it not run if
        # none of it's children will run
        if ($Block.ShouldRun) {
            $testsToRun = foreach ($t in $tests) { if ($t.ShouldRun) { $t } }
            if (any $testsToRun) {
                $testsToRun[0].First = $true
                $testsToRun[-1].Last = $true
                $blockShouldRun = $true
            }
        }
    }

    $childBlocks = $Block.Blocks
    $anyChildBlockShouldRun = $false
    if ($childBlocks.Count -gt 0) {
        foreach ($cb in $childBlocks) {
            $cb.Parent = $Block
            PostProcess-DiscoveredBlock -Block $cb -Filter $Filter -BlockContainer $BlockContainer -RootBlock $RootBlock
        }

        $childBlocksToRun = foreach ($b in $childBlocks) { if ($b.ShouldRun) { $b } }
        $anyChildBlockShouldRun = any $childBlocksToRun
        if ($anyChildBlockShouldRun) {
            $childBlocksToRun[0].First = $true
            $childBlocksToRun[-1].Last = $true
        }
    }

    $shouldRunBasedOnChildren = $blockShouldRun -or $anyChildBlockShouldRun

    if ($Block.ShouldRun -and -not $shouldRunBasedOnChildren) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope RuntimeFilter "($($Block.Path -join '.')) Block was marked as Should run based on filters, but none of its tests or tests in children blocks were marked as should run. So the block won't run."
        }
    }

    $Block.ShouldRun = $shouldRunBasedOnChildren
}


function PostProcess-ExecutedBlock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName("DiscoveredBlock")][PSObject[]] $Block
    )


    # traverses the block structure after a block was executed and
    # and sets the failures correctly so the aggreagatted failures
    # propagate towards the root so if a child test fails it's block
    # aggregated result should be marked as failed

    process {
        foreach ($b in $Block) {
            $thisBlockFailed = -not $b.OwnPassed

            $b.OwnTotalCount = 0
            $b.OwnFailedCount = 0
            $b.OwnPassedCount = 0
            $b.OwnSkippedCount = 0
            $b.OwnNotRunCount = 0

            $testDuration = [TimeSpan]::Zero

            foreach ($t in $b.Tests) {
                $testDuration += $t.Duration

                $b.OwnTotalCount++
                if (-not $t.ShouldRun) {
                    $b.OwnNotRunCount++
                }
                elseif  ($t.ShouldRun -and $t.Skipped) {
                    $b.OwnSkippedCount++
                }
                elseif (($t.Executed -and -not $t.Passed) -or ($t.ShouldRun -and -not $t.Executed)) {
                    # TODO:  this condition works but needs to be revisited. when the parent fails the test is marked as failed, because it should have run but it did not,and but there is no error in the test result, in such case all tests should probably add error or a flag that indicates that the parent failed, or a log or something, but error is probably the best
                    $b.OwnFailedCount++
                }
                elseif ($t.Executed -and $t.Passed) {
                    $b.OwnPassedCount++
                }
                else {
                    throw "Test '$($t.Name)' is in invalid state. $($t | Format-List -Force * | Out-String)"
                }
            }

            $anyTestFailed = 0 -lt $b.OwnFailedCount

            $childBlocks = $b.Blocks
            $anyChildBlockFailed = $false
            $aggregatedChildDuration = [TimeSpan]::Zero
            if (none $childBlocks) {
                # one thing to consider here is what happens when a block fails, in the current
                # excecution model the block can fail when a setup or teardown fails, with failed
                # setup it is easy all the tests in the block are considered failed, with teardown
                # not so much, when all tests pass and the teardown itself fails what should be the result?



                # todo: there are two concepts mixed with the "own", because the duration and the test counts act differently. With the counting we are using own as "the count of the tests in this block", but with duration the "own" means "self", that is how long this block itself has run, without the tests. This information might not be important but this should be cleared up before shipping. Same goes with the relation to failure, ownPassed means that the block itself passed (that is no setup or teardown failed in it), even though the underlying tests might fail.


                $b.OwnDuration = $b.Duration - $testDuration

                $b.Passed = -not ($thisBlockFailed -or $anyTestFailed)

                # we have no child blocks so the own counts are the same as the total counts
                $b.TotalCount = $b.OwnTotalCount
                $b.FailedCount = $b.OwnFailedCount
                $b.PassedCount = $b.OwnPassedCount
                $b.SkippedCount = $b.OwnSkippedCount
                $b.NotRunCount = $b.OwnNotRunCount
            }
            else {
                # when we have children we first let them process themselves and
                # then we add the results together (the recusion could reach to the parent and add the totals)
                # but that is difficult with the duration, so this way is less error prone
                PostProcess-ExecutedBlock -Block $childBlocks

                foreach ($child in $childBlocks) {
                    # check that no child block failed, the Passed is aggregate failed, so it will be false
                    # when any test fails in the child, or if the block itself fails
                    if (-not $child.Passed) {
                        $anyChildBlockFailed = $true
                    }

                    $aggregatedChildDuration += $child.Duration

                    $b.TotalCount += $child.TotalCount
                    $b.PassedCount += $child.PassedCount
                    $b.FailedCount += $child.FailedCount
                    $b.SkippedCount += $child.SkippedCount
                    $b.NotRunCount += $child.NotRunCount
                }

                # then we add counts from this block to the counts from the children blocks
                $b.TotalCount += $b.OwnTotalCount
                $b.PassedCount += $b.OwnPassedCount
                $b.FailedCount += $b.OwnFailedCount
                $b.SkippedCount += $b.OwnSkippedCount
                $b.NotRunCount += $b.OwnNotRunCount

                $b.Passed = -not ($thisBlockFailed -or $anyTestFailed -or $anyChildBlockFailed)
                $b.OwnDuration = $b.Duration - $testDuration - $aggregatedChildDuration
            }
        }
    }
}

function Where-Failed {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Block
    )

    $Block | View-Flat | where { $_.ShouldRun -and (-not $_.Executed -or -not $_.Passed) }
}

function View-Flat {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Block
    )

    begin {
        $tests = [System.Collections.Generic.List[Object]]@()
    }
    process {
        # TODO: normally I would output to pipeline but in fold there is accumulator and so it does not output
        foreach ($b in $Block) {
            Fold-Container $b -OnTest { param($t) $tests.Add($t) }
        }
    }

    end {
        $tests
    }
}

function flattenBlock ($Block, $Accumulator) {
    $Accumulator.Add($Block)
    if ($Block.Blocks.Count -eq 0) {
        return $Accumulator
    }

    foreach ($bl in $Block.Blocks) {
        flattenBlock -Block $bl -Accumulator $Accumulator
    }
    $Accumulator
}

function New-FilterObject {
    [CmdletBinding()]
    param (
        [String[][]] $Path,
        [String[]] $Tag,
        [String[]] $ExcludeTag,
        [String[]] $Line
    )

    New_PSObject -Type "Filter" -Property @{
        Path       = $Path
        Tag        = $Tag
        ExcludeTag = $ExcludeTag
        Line       = $Line
    }
}

function New-PluginObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Name,
        [Hashtable] $Configuration,
        [ScriptBlock] $Start,
        [ScriptBlock] $DiscoveryStart,
        [ScriptBlock] $ContainerDiscoveryStart,
        [ScriptBlock] $BlockDiscoveryStart,
        [ScriptBlock] $TestDiscoveryStart,
        [ScriptBlock] $TestDiscoveryEnd,
        [ScriptBlock] $BlockDiscoveryEnd,
        [ScriptBlock] $ContainerDiscoveryEnd,
        [ScriptBlock] $DiscoveryEnd,
        [ScriptBlock] $RunStart,
        [scriptblock] $ContainerRunStart,
        [ScriptBlock] $OneTimeBlockSetupStart,
        [ScriptBlock] $EachBlockSetupStart,
        [ScriptBlock] $OneTimeTestSetupStart,
        [ScriptBlock] $EachTestSetupStart,
        [ScriptBlock] $EachTestTeardownEnd,
        [ScriptBlock] $OneTimeTestTeardownEnd,
        [ScriptBlock] $EachBlockTeardownEnd,
        [ScriptBlock] $OneTimeBlockTeardownEnd,
        [ScriptBlock] $ContainerRunEnd,
        [ScriptBlock] $RunEnd,
        [ScriptBlock] $End
    )

    $h = @{
        Name                    = $Name
        Configuration           = $Configuration
        Start                   = $Start
        DiscoveryStart          = $DiscoveryStart
        ContainerDiscoveryStart = $ContainerDiscoveryStart
        BlockDiscoveryStart     = $BlockDiscoveryStart
        TestDiscoveryStart      = $TestDiscoveryStart
        TestDiscoveryEnd        = $TestDiscoveryEnd
        BlockDiscoveryEnd       = $BlockDiscoveryEnd
        ContainerDiscoveryEnd   = $ContainerDiscoveryEnd
        DiscoveryEnd            = $DiscoveryEnd
        RunStart                = $RunStart
        ContainerRunStart       = $ContainerRunStart
        OneTimeBlockSetupStart  = $OneTimeBlockSetupStart
        EachBlockSetupStart     = $EachBlockSetupStart
        OneTimeTestSetupStart   = $OneTimeTestSetupStart
        EachTestSetupStart      = $EachTestSetupStart
        EachTestTeardownEnd     = $EachTestTeardownEnd
        OneTimeTestTeardownEnd  = $OneTimeTestTeardownEnd
        EachBlockTeardownEnd    = $EachBlockTeardownEnd
        OneTimeBlockTeardownEnd = $OneTimeBlockTeardownEnd
        ContainerRunEnd         = $ContainerRunEnd
        RunEnd                  = $RunEnd
        End                     = $End
    }

    # enumerate to avoid modifying the key collection
    # when we edit the hashtable
    $keys = foreach ($k in $h.Keys) { $k }

    foreach ($k in $keys) {
        if ("Configuration" -eq $k -or "Name" -eq $k) {
            continue
        }

        $h.Add("Has$k", ($null -ne $h.$k))
    }

    New_PSObject -Type "Plugin" $h
}

function Invoke-BlockContainer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        # relaxing the type here, I need it to have two forms and
        # PowerShell cannot do that probably
        # [PSTypeName("BlockContainer"] | [PSTypeName("DiscoveredBlockContainer")]
        $BlockContainer,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState
    )

    switch ($BlockContainer.Type) {
        "ScriptBlock" { & $BlockContainer.Content }
        "File" { Invoke-File -Path $BlockContainer.Content.PSPath -SessionState $SessionState }
        default { throw [System.ArgumentOutOfRangeException]"" }
    }
}

function New-BlockContainerObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = "ScriptBlock")]
        [ScriptBlock] $ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = "Path")]
        [String] $Path,
        [Parameter(Mandatory, ParameterSetName = "File")]
        [System.IO.FileInfo] $File
    )

    $type, $content = switch ($PSCmdlet.ParameterSetName) {
        "ScriptBlock" { "ScriptBlock", $ScriptBlock }
        "Path" { "File", (Get-Item $Path) }
        "File" { "File", $File }
        default { throw [System.ArgumentOutOfRangeException]"" }
    }

    New_PSObject -Type "BlockContainer" @{
        Type    = $type
        Content = $content
    }
}

function New-DiscoveredBlockContainerObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSTypeName('BlockContainer')] $BlockContainer,
        [Parameter(Mandatory)]
        [PSTypeName('DiscoveredBlock')][PSObject[]] $Block
    )

    New_PSObject -Type "DiscoveredBlockContainer" @{
        Type    = $BlockContainer.Type
        Content = $BlockContainer.Content
        # I create a Root block to keep the discovery unaware of containers,
        # but I don't want to publish that root block because it contains properties
        # that do not make sense on container level like Name and Parent,
        # so here we don't want to take the root block but the blocks inside of it
        # and copy the rest of the meaningful properties
        Blocks  = $Block.Blocks
    }
}

function Invoke-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]
        $Path,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState
    )

    $sb = {
        param ($p)
        . $($p; Remove-Variable -Scope Local -Name p)
    }

    $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $SessionStateInternal = $SessionState.GetType().GetProperty('Internal', $flags).GetValue($SessionState, $null)

    # attach the original session state to the wrapper scriptblock
    # making it invoke in the caller session state
    $sb.GetType().GetProperty('SessionStateInternal', $flags).SetValue($sb, $SessionStateInternal, $null)

    # dot source the caller bound scriptblock which imports it into user scope
    & $sb $Path
}

function Import-Dependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Dependency,
        # [Parameter(Mandatory=$true)]
        [Management.Automation.SessionState] $SessionState
    )

    if ($Dependency -is [ScriptBlock]) {
        . $Dependency
    }
    else {

        # when importing a file we need to
        # dot source it into the user scope, the path has
        # no bound session state, so simply dot sourcing it would
        # import it into module scope
        # instead we wrap it into a scriptblock that we attach to user
        # scope, and dot source the file, that will import the functions into
        # that script block, and then we dot source it again to import it
        # into the caller scope, effectively defining the functions there
        $sb = {
            param ($p)

            . $($p; Remove-Variable -Scope Local -Name p)
        }

        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $SessionStateInternal = $SessionState.GetType().GetProperty('Internal', $flags).GetValue($SessionState, $null)

        # attach the original session state to the wrapper scriptblock
        # making it invoke in the caller session state
        $sb.GetType().GetProperty('SessionStateInternal', $flags).SetValue($sb, $SessionStateInternal, $null)

        # dot source the caller bound scriptblock which imports it into user scope
        . $sb $Dependency
    }
}

function Add-FrameworkDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Dependency
    )

    # adds dependency that is dotsourced during discovery & execution
    # this should be rarely needed, but is useful when you wrap Pester pieces
    # into your own functions, and want to have them available during both
    # discovery and execution
    if ($PesterPreference.Debug.WriteDebugMessages.Value) {
        Write-PesterDebugMessage -Scope Runtime "Adding framework dependency '$Dependency'"
    }
    Import-Dependency -Dependency $Dependency -SessionState $SessionState
}

function Add-Dependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Dependency,
        [Parameter(Mandatory = $true)]
        [Management.Automation.SessionState] $SessionState
    )


    # adds dependency that is dotsourced after discovery and before execution
    if (-not (Is-Discovery)) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Adding run-time dependency '$Dependency'"
        }
        Import-Dependency -Dependency $Dependency -SessionState $SessionState
    }
}

function Anywhere {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock
    )

    # runs piece of code during execution, useful for backwards compatibility
    # when you have stuff laying around inbetween describes and want to run it
    # only during execution and not twice. works the same as Add-Dependency, but I name
    # it differently because this is a bad-practice mitigation tool and should probably
    # write a warning to make you use Before* blocks instead
    if (-not (Is-Discovery)) {
        if ($PesterPreference.Debug.WriteDebugMessages.Value) {
            Write-PesterDebugMessage -Scope Runtime "Invoking free floating piece of code"
        }
        Import-Dependency $ScriptBlock
    }
}

function New-ParametrizedTest () {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $Name,
        [Parameter(Mandatory = $true, Position = 1)]
        [ScriptBlock] $ScriptBlock,
        [String[]] $Tag = @(),
        # do not use [hashtable[]] because that throws away the order if user uses [ordered] hashtable
        [System.Collections.IDictionary[]] $Data = @{ },
        [Switch] $Focus,
        [Switch] $Skip
    )

    Switch-Timer -Scope Framework
    # TODO: there used to be counter, that was added to the id, seems like I am missing TestGroup on the test cases, so I can reconcile them back if they were generated from testcases
    # $counter = 0

    # using the start line of the scriptblock as the id of the test so we can join multiple testcases together, this should be unique enough because it only needs to be unique for the current block, so the way to break this would be to inline multiple tests, but that is unlikely to happen. When it happens just use StartLine:StartPosition
    $id = $ScriptBlock.StartPosition.StartLine
    foreach ($d in $Data) {
    #    $innerId = if (-not $hasExternalId) { $null } else { "$Id-$(($counter++))" }
        New-Test -Id $id -Name $Name -Tag $Tag -ScriptBlock $ScriptBlock -Data $d -Focus:$Focus -Skip:$Skip
    }
}

function Recurse-Up {
    param(
        [Parameter(Mandatory)]
        $InputObject,
        [ScriptBlock] $Action
    )

    $i = $InputObject
    $level = 0
    while ($null -ne $i) {
        &$Action $i

        $level--
        $i = $i.Parent
    }
}

function New-PreviousItemObject {

    param ()
    New_PSObject -Type 'PreviousItemInfo' @{
        Any      = $false
        Location = 0
        Counter  = 0
        # just for debugging, not being able to use the name to identify tests, because of
        # potential expanding variables in the names, is the whole reason the position of the
        # sb is used
        Name     = $null
    }
}

function ConvertTo-HumanTime {
    param ([TimeSpan]$TimeSpan)
    if ($TimeSpan.Ticks -lt [timespan]::TicksPerSecond) {
        "$([int]($TimeSpan.TotalMilliseconds))ms"
    }
    else {
        "$([int]($TimeSpan.TotalSeconds))s"
    }
}

function Assert-InvokedNonInteractively () {
    if (-not $ExecutionContext.SessionState.PSVariable.Get("InvokedNonInteractively")) {
        throw "Running tests interactively (e.g. by pressing F5 in your IDE) is not supported, run tests via Invoke-Pester."
    }
}

Import-Module $PSScriptRoot\stack.psm1 -DisableNameChecking
# initialize internal state
Reset-TestSuiteState

Export-ModuleMember -Function @(
    # the core stuff I am mostly sure about
    'Reset-TestSuiteState'
    'New-Block'
    'New-Test'
    'New-ParametrizedTest'
    'New-EachTestSetup'
    'New-EachTestTeardown'
    'New-OneTimeTestSetup'
    'New-OneTimeTestTeardown'
    'New-EachBlockSetup'
    'New-EachBlockTeardown'
    'New-OneTimeBlockSetup'
    'New-OneTimeBlockTeardown'
    'Add-FrameworkDependency'
    'Anywhere'
    'Invoke-Test',
    'Find-Test',
    'Invoke-PluginStep'

    # here I have doubts if that is too much to expose
    'Get-CurrentTest'
    'Get-CurrentBlock'
    'Recurse-Up',
    'Is-Discovery'

    # those are quickly implemented to be useful for demo
    'Where-Failed'
    'View-Flat'

    # those need to be refined and probably wrapped to something
    # that is like an object builder
    'New-FilterObject'
    'New-PluginObject'
    'New-BlockContainerObject'
)