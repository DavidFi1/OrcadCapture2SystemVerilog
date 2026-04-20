# dsn2sv.tcl
#
# This script traverses a Cadence Capture schematic design hierarchy and generates SystemVerilog
# module files for each unique schematic page encountered. Each generated module
# includes port definitions with bus widths, and instantiations of components
# found on the corresponding schematic page.
#
# Key Features:
# - Hierarchical traversal: Explores the entire schematic hierarchy, generating a .sv file for each page.
# - Page de-duplication: Ensures each unique page is processed only once, even if referenced multiple times.
# - Name sanitization: Converts schematic names (ports, nets, instances) into valid SystemVerilog identifiers.
# - Component Grouping & Sorting: Simple components are grouped by their module name and then sorted by reference designator.
# - Pin Uniqueness: Pin names in SystemVerilog output are made unique by appending their pin number.
# - Debugging: Includes optional debug messages to trace execution flow.

# --- Configuration ---
# Set to 1 to enable detailed debug messages, 0 to disable.
set ::gDebug 1
# Directory where the generated SystemVerilog (.sv) files will be stored.
set ::outputDir "dsn_sv"

# --- Helper Procedures ---

# print_debug: Outputs a debug message if the global ::gDebug flag is set to 1.
# Arguments:
#   msg - The debug message string to print.
proc print_debug {msg} {
    if {$::gDebug} {
        global debugFileHandle
        if {[info exists debugFileHandle] && $debugFileHandle != ""} {
            puts $debugFileHandle "DEBUG: $msg"
        } else {
            # Fallback to stdout if file handle not set (e.g., during very early errors)
            puts "DEBUG: $msg"
        }
    }
}

# sanitize_name: Converts a given name string into a valid SystemVerilog identifier.
# It handles special characters, leading digits, and empty names.
# Arguments:
#   name - The original name string from the schematic.
# Returns:
#   A sanitized string suitable for use as a SystemVerilog identifier.
proc sanitize_name {name} {
    # Replaces common problematic characters with 'n' or 'P' for negative/positive, or removes them.
    set sanitized_name [string map {
        " "   "_" 
        "\\"  "n"
        "|"   "Or"
        "&"   "And"
        "/"   "_"
        ".."  ":"
        "\n"  ""
        "\r"  ""
        "-"  "n"
        "+"  "p"
        ","  "_"
        "#"  "_"
        "."  "d"
        } $name ]
    # Replace multiple consecutive underscores with a single underscore.
    regsub -all {_+} $sanitized_name "_" sanitized_name

    # Prepends 'p' if the name starts with a digit to ensure it's a valid identifier.
    if {[regexp {^[0-9]}      $sanitized_name]} {
        set sanitized_name "P${sanitized_name}"
    }
    # Trims leading/trailing underscores.
    set sanitized_name [string trim   $sanitized_name "_"]
    # Trims leading/trailing whitespace.
    set sanitized_name [string trim   $sanitized_name    ]
    # Handles cases where sanitization results in an empty string.
    if {$sanitized_name eq ""} {
        return "unnamed"
    }
    return $sanitized_name
}

# getPartNumber: Returns the component Value (visible on schematic) from PartInst.
# This is typically used as the module name for primitives.
proc getPartNumber { pPartInst } {
    print_debug " getPartNumber $pPartInst of type [$pPartInst GetObjectType]"
    set lValue ""
    if {[catch {
        set lValueCS [DboTclHelper_sMakeCString]
        $pPartInst GetPartValue $lValueCS
        set lValue   [DboTclHelper_sGetConstCharPtr $lValueCS]
    } err]} {
        print_debug " getPartNumber GetPartValue failed"
        return ""
    }
    print_debug     " getPartNumber returned $lValue"
    set lValue [sanitize_name $lValue]
    return $lValue
}

proc process_off_page_connectors {lPage lStatus} {
    set ports [dict create]
    if {![catch {$lPage NewOffPageConnectorsIter $lStatus} lOffPageIter]} {
        set lOffPage [$lOffPageIter NextOffPageConnector $lStatus]
        while {$lOffPage != "NULL"} {
            set lOffPageNameCS [DboTclHelper_sMakeCString]
            $lOffPage GetName $lOffPageNameCS
            set OffPageName [DboTclHelper_sGetConstCharPtr $lOffPageNameCS]
            set sanitizedOffPageName [sanitize_name $OffPageName]
            print_debug "    Found Off-Page: '$sanitizedOffPageName' -> Name: '$OffPageName'"
            dict set ports $sanitizedOffPageName "    inout    $sanitizedOffPageName"

            set lOffPage [$lOffPageIter NextOffPageConnector $lStatus]
        }
        delete_DboPageOffPageConnectorsIter $lOffPageIter
    }
    return $ports
}

proc process_globals {lPage lStatus} {
    print_debug "process_globals page: $lPage"
    set ports [dict create]
    if {![catch {$lPage NewGlobalsIter $lStatus} lGlobalsIter]} {
        set lGlobal [$lGlobalsIter NextGlobal $lStatus]
        while {$lGlobal != "NULL"} {
            set lGlobalNameCS [DboTclHelper_sMakeCString]
            $lGlobal GetName $lGlobalNameCS
            set GlobalName [DboTclHelper_sGetConstCharPtr $lGlobalNameCS]
            print_debug "process_globals GlobalName: $GlobalName "
            set formattedGlobalName [sanitize_name $GlobalName]

            dict set ports $formattedGlobalName "    input    $formattedGlobalName"

            set lGlobal [$lGlobalsIter NextGlobal $lStatus]
        }
        delete_DboPageGlobalsIter $lGlobalsIter
    }
    return $ports
}

proc GetPinDirection {lPort lStatus} {
    set lPinTypeInt [$lPort GetPinType $lStatus]
    set lPortDirectionString "" 
    switch $lPinTypeInt {
        0       { set lPortDirectionString "input"                  } 
        1       { set lPortDirectionString "output"                 } 
        2       { set lPortDirectionString "inout"                  } 
        3       { set lPortDirectionString "output"                 } ;# pullup
        4       { set lPortDirectionString "output"                 } ;# pullup
        5       { set lPortDirectionString "output"                 } ;# pullup
        6       { set lPortDirectionString "output"                 } ;# pulldown
        7       { set lPortDirectionString "inout"                  }
        default { set lPortDirectionString "unknown ($lPinTypeInt)" }
    }
    return $lPortDirectionString
}

proc process_hierarchical_ports {lPage lStatus} {
    set ports [dict create]
    if {![catch {$lPage NewPortsIter $lStatus} lPortsIter]} {
         set lPort [$lPortsIter NextPort $lStatus]
         while {$lPort != "NULL"} {
            set lPortDirectionString [GetPinDirection $lPort $lStatus]
            set lPortNameCS [DboTclHelper_sMakeCString]
            $lPort GetName $lPortNameCS
            set lPortName   [DboTclHelper_sGetConstCharPtr $lPortNameCS]
            set formattedPortName [sanitize_name $lPortName]
            
            set sv_port_string "    $lPortDirectionString    $formattedPortName"
            dict set ports $formattedPortName $sv_port_string
 
            set lPort [$lPortsIter NextPort $lStatus]
        }
        delete_DboPagePortsIter $lPortsIter
    }
    return $ports
}

# CollectComponentData: Gathers component data by iterating through logical part instances.
# Returns:
#       all_instances             
#       block_pages_for_recursion 
proc CollectComponentData {lPage status lDesign} {
    set debugPageNameCStr [DboTclHelper_sMakeCString]
    $lPage GetName $debugPageNameCStr
    set pageName [DboTclHelper_sGetConstCharPtr $debugPageNameCStr]
    print_debug "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    print_debug "Entering CollectComponentData for page: $pageName"
    print_debug "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    set final_instances           {}
    set block_pages_for_recursion {}

    # Iterate through all logical Part Instances on the page 
    # and get a name composed of all the refDes of this part
    if {![catch {$lPage NewPartInstsIter $status} lPartInstsIter]} {
        set lPartInst [$lPartInstsIter NextPartInst $status]
        while {$lPartInst != "NULL"} {
            print_debug "  Processing PartInst: $lPartInst type: [$lPartInst GetObjectType]"

            # Using as a part name all the Reference Designators of this part concateneated with "_"
            set concatenatedRefDes ""
            # 1. Get the total count of occurrences for this part instance
            set lOccCount [$lPartInst GetOccurrencesCount]

            # 2. Loop through the occurrences by their position index
            for {set i 0} {$i < $lOccCount} {incr i} {
                # Get the occurrence at the current index
                set lOcc [$lPartInst GetOccurrencesAtPos $i]
                
                if {$lOcc != "NULL"} {
                    # 3. Cast to Instance Occurrence to access RefDes
                    set lInstOcc [DboOccurrenceToDboInstOccurrence $lOcc]
                    
                    # 4. Extract the RefDes
                    set lRefDes [DboTclHelper_sMakeCString]
                    $lInstOcc GetReference $lRefDes
                    
                    set finalRefDes [DboTclHelper_sGetConstCharPtr $lRefDes]
                    if {$i > 0} {
                        # after the first RefDes add "_" before the next RefDes
                        append concatenatedRefDes _
                    }
                    append concatenatedRefDes $finalRefDes
                    print_debug "Occurrence $i RefDes: $finalRefDes"
                }
            }
            print_debug "  concatenatedRefDes for RefDes: '$concatenatedRefDes'"

            # Determine module name (primitive vs. hierarchical)
            set moduleName ""
            if {![$lPartInst IsPrimitive $status]} {
                print_debug "    Instance '$concatenatedRefDes' is a hierarchical block."
                set lChildView [$lPartInst GetContents $status]
                if {$lChildView != "NULL"} {
                    set lChildSchematic [DboViewToDboSchematic $lChildView]
                    set childPagesList {}
                    if {![catch {$lChildSchematic NewPagesIter $status} lChildPagesIter]} {
                        set lChildPage [$lChildPagesIter NextPage $status]
                        while {$lChildPage != "NULL"} {
                            lappend childPagesList $lChildPage
                            set lChildPage [$lChildPagesIter NextPage $status]
                        }
                        delete_DboSchematicPagesIter $lChildPagesIter
                    }

                    if {[llength $childPagesList] > 0} {
                        set firstChildPage  [lindex $childPagesList 0]
                        set childPageNameCS [DboTclHelper_sMakeCString]
                        $firstChildPage GetName $childPageNameCS
                        set moduleName [sanitize_name [DboTclHelper_sGetConstCharPtr $childPageNameCS]]
                        
                        foreach lChildPage $childPagesList {
                            lappend block_pages_for_recursion [list $concatenatedRefDes $lChildPage]
                        }
                    } else { 
                        set moduleName "unnamed_child_module" 
                    }
                } else { 
                        set moduleName "unlinked_block" 
                }
                print_debug "    Module name (hierarchical): $moduleName"
            } else {
                print_debug "    Instance '$concatenatedRefDes' is a primitive component."
                # Use Value (component value visible on schematic) as module name; fallback to Part Number
                set moduleName [getPartNumber $lPartInst]
                if {$moduleName == "NULL" || $moduleName == ""} {
                    set moduleName "undefined_module"

                } else {
                    set moduleName [sanitize_name $moduleName]
                }
                print_debug "    Module name (primitive): $moduleName"
            }

            # Collect Pin and Net data from logical pins (PartInst NewPinsIter -> Pin GetNet)
            set pins_connections_map [dict create]
            if {![catch {$lPartInst NewPinsIter $status} lPinsIter]} {
                set lPin [$lPinsIter NextPin $status]
                while {$lPin != "NULL"} {
                    set lPinNameCS [DboTclHelper_sMakeCString]
                    $lPin GetPinName $lPinNameCS
                    set pinName [DboTclHelper_sGetConstCharPtr $lPinNameCS]

                    set pinNumber ""
                    if {![catch {$lPin GetPinNumber $status} pNum]} { 
                        set pinNumber $pNum 
                    }

                    set pinIdentifier [sanitize_name "${pinName}_${pinNumber}"]
                    # in sv components "Pin name" is without the [7:0] 
                    regsub -all {\[[^\]]*\]} $pinIdentifier "" pinIdentifier

                    # get direction inout input output
                    set direction [GetPinDirection $lPin $status]

                    # Get net from logical pin directly (works without occurrences)
                    set netName ""
                    if {![catch {set lNet [$lPin GetNet $status]} netErr]} {
                        if {$lNet != "NULL"} {
                            set netNameCS [DboTclHelper_sMakeCString]
                            if       {![catch {$lNet GetNetName $netNameCS} nameErr ]} {
                                set netName [sanitize_name [DboTclHelper_sGetConstCharPtr $netNameCS]]

                            } elseif {![catch {$lNet GetName    $netNameCS} nameErr2]} {
                                set netName [sanitize_name [DboTclHelper_sGetConstCharPtr $netNameCS]]
                            }
                        }
                    }
                    dict set pins_connections_map $pinIdentifier [list $pinIdentifier $direction $netName]
                    print_debug "    Pin: $pinIdentifier ($direction)-> net: $netName"
                    
                    set lPin [$lPinsIter NextPin $status]
                }
                delete_DboPartInstPinsIter $lPinsIter
            }

            # add to pins_connections_map the global pins of the page in an hirarchial component
            
            lappend final_instances [dict create \
                module_name $moduleName \
                ref_designator   [sanitize_name $concatenatedRefDes  ] \
                instance_name    [sanitize_name $concatenatedRefDes  ] \
                pins_connections [dict values   $pins_connections_map] \
            ]

            set lPartInst [$lPartInstsIter NextPartInst $status]
        }
        delete_DboPagePartInstsIter $lPartInstsIter
    }

    # --- Merge multipart components (e.g. U7A, U7B, U7C -> U7 with all pins combined) ---
    # Components with same base ref des (strip trailing letter) are parts of the same physical component.
    print_debug "MERGE: Starting merge of [llength $final_instances] instances."
    set merged_instances [dict create]
    foreach instance_data $final_instances {
        set fullRefDes [dict get $instance_data ref_designator]
#       set moduleName [dict get $instance_data module_name   ]

        # Strip trailing letter(s) to get base ref des: U7A->U7, U7B->U7, R123->R123
        regsub {(\d)[A-Z]+$} $fullRefDes {\1} baseRefDes 
        print_debug "MERGE: '$fullRefDes' -> base '$baseRefDes'"

        if {![dict exists $merged_instances $baseRefDes]} {
            # If this baseRefDes hasn't been seen yet, add it to the dictionary.
            # We replace the original "U7A" with the cleaned "U7" label.
            dict set       merged_instances $baseRefDes [\
                dict replace $instance_data    \
                    ref_designator $baseRefDes \
                    instance_name  $baseRefDes           ]
        } else {
            # If the baseRefDes ALREADY exists (e.g., we already processed U7A and now we are on U7B):
            set existing      [dict get $merged_instances $baseRefDes]
            set existing_pins [dict get $existing      pins_connections]
            set new_pins      [dict get $instance_data pins_connections]

            # Use dict to deduplicate by pin identifier (pin name); same pin from multiple parts -> keep one
            set pins_dict [dict create]
            foreach pin_data $existing_pins {
                set  pin_id [lindex $pin_data 0]
                dict set pins_dict $pin_id $pin_data
            }
            foreach pin_data $new_pins {
                set  pin_id [lindex $pin_data 0]
                dict set pins_dict $pin_id $pin_data
            }
            set all_pins [dict values $pins_dict]
            dict set merged_instances $baseRefDes [\
                dict replace $existing pins_connections $all_pins]
        }
    }
    set final_instances [dict values $merged_instances]

    print_debug "MERGE: Complete. [llength $final_instances] instances after merge."
    print_debug "Exiting CollectComponentData for page: $pageName."
    return [dict create \
        all_instances             $final_instances           \
        block_pages_for_recursion $block_pages_for_recursion ]
}

# CollectPageData: Gathers all relevant data (ports, nets, components) from a schematic page.
# Arguments:
#   lPage   - The DboPage   object to collect data from.
#   status  - The DboState  object for API calls.
#   lDesign - The DboDesign object.
# Returns:
#   A dictionary containing :
#       ports                     all_ports                 
#       nets                      nets                      
#       all_instances             all_instances             
#       block_pages_for_recursion block_pages_for_recursion 
proc CollectPageData {lPage status lDesign} {
    print_debug "inside CollectPageData"

    set all_ports  [dict create]
    set temp_ports [process_hierarchical_ports  $lPage $status]
    dict for {k v} $temp_ports { dict set all_ports $k $v }

    set temp_ports [process_globals             $lPage $status]
    dict for {k v} $temp_ports { dict set all_ports $k $v }

    set temp_ports [process_off_page_connectors $lPage $status]
    dict for {k v} $temp_ports { dict set all_ports $k $v }
    
    set sorted_port_names [lsort -unique [dict keys $all_ports]]

    # Collect component data (primitive and hierarchical instances)
    set componentData             [CollectComponentData $lPage $status $lDesign     ]
    set all_instances             [dict get $componentData all_instances            ]
    set block_pages_for_recursion [dict get $componentData block_pages_for_recursion]

    # Collect all unique net names from component pin connections
    set nets [dict create]
    foreach instance_data $all_instances {
        set pins_connections [dict get $instance_data pins_connections]
        foreach pin_data $pins_connections {
            set connectedNetName [lindex $pin_data 2]
            if {$connectedNetName != ""} {
                dict set nets $connectedNetName 1
            }
        }
    }

    return [dict create \
        ports                     $all_ports                 \
        nets                      $nets                      \
        all_instances             $all_instances             \
        block_pages_for_recursion $block_pages_for_recursion ]
}

# --- Core Generation Procedure ---
proc Wires2VectorsAndScalars {signal_list} {
    array set min_val   {}
    array set max_val   {}
    array set direction {} ;# 1 for ascending, 0 for descending

    # 1. Identify "True Vectors" and their initial direction
    foreach sig $signal_list {
        if       {[regexp {^(\w+)\[(\d+):(\d+)\]$} $sig -> name b1 b2]} {
            # found AN[1:5]
            print_debug "inside Wires2VectorsAndScalars found AN\[1:5\] - sig: $sig -> $name $b1 $b2 "
            set direction($name) [expr {$b1 < $b2 ? 1   : 0  }]
            set low              [expr {$b1 < $b2 ? $b1 : $b2}]
            set high             [expr {$b1 > $b2 ? $b1 : $b2}]
            if {![info exists min_val($name)] || 
                     $low  < $min_val($name)}  { 
                set           min_val($name) $low 
            }
            if {![info exists max_val($name)] || 
                     $high > $max_val($name)} { 
                set           max_val($name) $high 
            }            
        } elseif {[regexp {^(\w+)\[(\d+)\]$}       $sig -> name idx  ]} {
            # found AN[6]
            print_debug "inside Wires2VectorsAndScalars found AN\[6\] - sig: $sig -> $name $idx "
            if {![info exists min_val($name)] || 
                     $idx  < $min_val($name)  }  { 
                set           min_val($name) $idx 
            }
            if {![info exists max_val($name)] || 
                     $idx  > $max_val($name)} { 
                set           max_val($name) $idx 
            }
        }
    }

    # 2. extend vectors range to include the index of Alpha-Numeric (AN9, BN5) vectors
    #    and generate scalars list
    set scalars {}
    foreach sig $signal_list {
        if       { [regexp {^([a-zA-Z_]+)(\d+)$} $sig -> name idx] } {
            # found AN9
            if {[info exists min_val($name)]} {
                # AN9 is a vector - extend this vector range:
                print_debug "inside Wires2VectorsAndScalars found AN9 - sig: $sig -> $name $idx "
                if { $idx < $min_val($name)} { 
                    set      min_val($name) $idx 
                }
                if {$idx >  $max_val($name)} { 
                    set      max_val($name) $idx 
                }
            } else {
                # BN5 is not a vectore - add it to scalars list
                print_debug "inside Wires2VectorsAndScalars found BN5 - sig: $sig "
                lappend scalars $sig
            }
        } elseif { [regexp {.*[^0-9\]]$}         $sig            ] } {
                # BN  is not a vectore - add it to scalars list ( not vector like AN[1] nor AN[1:5] )
                print_debug "inside Wires2VectorsAndScalars found BN  - sig: $sig "
                lappend scalars $sig
        }
    }

    # 3. Format output based on stored direction
    set vectors       {}
    set vectors_names {}
    foreach name [lsort [array names min_val]] {
        set      low           $min_val($name)
        set      high          $max_val($name)
        lappend  vectors_names ${name}
        
        # Default to descending [high:low] if no range was ever provided (just single bits)
        if { $low ne $high } {
            if { $direction($name) == 0 } {
                print_debug "inside Wires2VectorsAndScalars descending  - ${name}\[${high}:${low}\] "
                lappend vectors "${name}\[${high}:${low}\]"

            } else {
                print_debug "inside Wires2VectorsAndScalars  ascending  - ${name}\[${low}:${high}\] "
                lappend vectors "${name}\[${low}:${high}\]"
            }
        } else {
                print_debug "inside Wires2VectorsAndScalars low eq high - ${name}\[${low}\] '${high}'"
                lappend vectors "${name}\[${low}\]"
        }
    }
    set all_nets [lsort -unique [concat $vectors $scalars]]

    return [list $all_nets $vectors_names ]
}

# GenerateSvForPage: Generates a SystemVerilog module file for a single schematic page.
# Arguments:
#   lPage  - The DboPage object for which to generate the SV file.
#   status - The DboState object for API calls.
proc GenerateSvForPage {lPage status pageData} {
    print_debug "inside GenerateSvForPage - Page object: $lPage"

    # Get and sanitize the page name for use as a module name and filename
    set pageNameCS [DboTclHelper_sMakeCString]
    $lPage GetName $pageNameCS
    set pageName [DboTclHelper_sGetConstCharPtr $pageNameCS]
    set sanitizedPageName [sanitize_name $pageName]

    print_debug "Attempting to generate SV for page: $pageName"

    # --- Part 2: File Writing ---
    set filePath "$::outputDir/$sanitizedPageName.sv"
    puts "Processing page '$pageName' -> $filePath"
    
    # Attempt to open the file for writing
    if {[catch {open $filePath "w"} fid]} {
        puts "Error: Could not open file for writing: $filePath"
        return
    } else {
        print_debug "Successfully opened file: $filePath"
    }
    
    # Write header comment
    puts $fid "// Generated from page: $pageName\n"
    print_debug "DBG-2: After writing header comment."

    # Write module header with port declarations
    set port_declarations [list]
    set ports [dict get $pageData ports]
    print_debug "DBG-3: After getting ports. [llength [dict keys $ports]] ports found."

    # Iterate through collected ports, sanitize names, and format them
    set port_counter 0
    dict for {portName details} $ports {
        incr port_counter
        print_debug "DBG-4.$port_counter: Processing port '$portName'."

        # 'details' is the full string, e.g., "    inout    portName;"
        lappend port_declarations "    [string trim $details]"
        print_debug "DBG-4.$port_counter: Appended port declaration."
    }
    puts $fid "module $sanitizedPageName ("
    if {[llength $port_declarations] > 0} {
        puts $fid [join $port_declarations ",\n"]
    }
    puts $fid ");\n"
    print_debug "DBG-6: After writing module header."
    
    # Write wire declarations for internal nets
    puts $fid "\n"
    set nets [dict keys [dict get $pageData nets]]
    print_debug "DBG-7: After getting nets. [llength $nets] nets found."

    lassign [ Wires2VectorsAndScalars $nets ] nets vectors 
    print_debug "DBG-7.1: After consolidate_dict_nets nets. [ llength $nets ] nets found."

    # Only declare nets as wires if they are not already ports of the module
    set net_counter 0
    foreach net_name $nets {
        incr net_counter
        print_debug "DBG-8.$net_counter: Processing net '$net_name'."
        set sanitized_net_name [sanitize_name $net_name]
        print_debug "DBG-8.$net_counter: Sanitized net name: '$sanitized_net_name'."
        if {![dict exists $ports $sanitized_net_name]} { 
            puts $fid "    wire $sanitized_net_name;"
            print_debug "DBG-8.$net_counter: Wrote wire declaration."

        } else {
            print_debug "DBG-8.$net_counter: Net '$sanitized_net_name' is already a port. Skipping wire declaration."
        }
    }
    puts $fid "\n"
    print_debug "DBG-9: After wire declarations."

    # Write component instantiations (primitive and hierarchical)
    print_debug "DBG-10: Starting component instantiations section."
    set ::unnamed_counter 0
    set all_instances [dict get $pageData all_instances]

    # Group instances by their module name for consistent output
    set grouped_instances [dict create]
    
    foreach instance_data $all_instances {
        set moduleName [dict get $instance_data module_name]
        dict lappend grouped_instances $moduleName $instance_data
    }
    print_debug "DBG-10.1: Total instances found on page: [llength $all_instances]"
    print_debug "DBG-10.2: Instances grouped into [llength [dict keys $grouped_instances]] unique module types."

    # Sort module names alphabetically for consistent output order
    set sorted_module_names [lsort -dictionary [dict keys $grouped_instances]]

    # Iterate through each module group
    foreach moduleName $sorted_module_names {
        if {[catch {set instances_of_module [dict get $grouped_instances $moduleName]} result]} {
            print_debug "Warning: Could not retrieve instances for module '$moduleName'. Error: $result"
            continue
        }

        # Sort instances within the module group by their reference designator
        set sorted_instances_of_module [
            lsort -dictionary -command {
                apply {{a b} {
                    set refA [dict get $a ref_designator]
                    set refB [dict get $b ref_designator]
                    return   [string compare $refA $refB]
                }}
            } $instances_of_module
        ]

        # Generate instantiation code for each sorted instance
        foreach instance_data $sorted_instances_of_module {
            set moduleName [dict get $instance_data module_name  ]
            set instName   [dict get $instance_data instance_name]
            
            if {$instName eq "" || $instName eq "unnamed"} {
                set instName "unnamed_instance_[incr ::unnamed_counter]"
            }

            puts $fid "    $moduleName $instName ("
            set pin_connections_formatted [list]
            set pins_list [dict get $instance_data pins_connections]
            print_debug "DBG-11: Processing instance '$instName' pins:"

            foreach pin_data $pins_list {
                set formattedPinName [lindex $pin_data 0] ; # Sanitized pin name
                set connectedNetName [lindex $pin_data 2] ; # Sanitized connected net name
                # convert connectedNetName to vector format if its name is in the vectors list
                if {[regexp {^([a-zA-Z_]+)(\d+)$} $connectedNetName -> name idx]} {
                    if {$name in $vectors} {
                        # Change AN7 to AN[7]
                        set connectedNetName "${name}\[${idx}\]"
                    }
                }

                print_debug "DBG-11.1:   Pin: '$formattedPinName', Connected to Net: '$connectedNetName'"
                lappend pin_connections_formatted [format "        .%s(%s)" $formattedPinName $connectedNetName]
            }
            puts $fid [join $pin_connections_formatted ",\n"]
            puts $fid "    );"
        }
    }
    
    puts  $fid "endmodule"
    close $fid
    print_debug "Closed file: $filePath"
}
# --- Traversal Procedures ---

# TraverseAndGenerate: Recursively traverses the schematic hierarchy, generating SV files for each unique page.
# This procedure uses a global array (::gProcessedPages) to ensure each page is processed only once,
# preventing infinite loops in cyclic or re-entrant hierarchical designs.
# Arguments:
#   lPage   - The DboPage object representing the current schematic page to process and traverse from.
#   lDesign - The DboDesign object.
proc TraverseAndGenerate {lPage lDesign} {
    set debugPageNameCStr [DboTclHelper_sMakeCString]
    $lPage GetName $debugPageNameCStr
    set pageNameForTracking [DboTclHelper_sGetConstCharPtr $debugPageNameCStr]

    print_debug "Entering TraverseAndGenerate for page: $pageNameForTracking" 
    # Check if this page has already been processed. If so, return to avoid re-processing and infinite loops.
    if {[info exists ::gProcessedPages($pageNameForTracking)]} {
        print_debug "Page already processed: $pageNameForTracking. Skipping."
        return
    }
    # Mark the current page as processed using its unique name as the key.
    set ::gProcessedPages($pageNameForTracking) 1
    print_debug "Processing Page : $pageNameForTracking."
    
    # Collect all data for the current page
    set pageData    [CollectPageData $lPage [DboState] $lDesign]
    print_debug "Got CollectPageData from Page : $pageNameForTracking."

    # Generate the SystemVerilog module for the current page.
    GenerateSvForPage $lPage [DboState] $pageData
    print_debug "finished GenerateSvForPage of : $pageNameForTracking."

    # Find all hierarchical blocks on this page and recursively process their linked child pages.
    set blockPages [dict get $pageData block_pages_for_recursion]
    foreach blockPageTuple $blockPages {
        set childPage [lindex $blockPageTuple 1]
        TraverseAndGenerate $childPage $lDesign
    }
}


# --- Main Execution Procedure ---

# RunSvGeneration: The main entry point for the script.
# It initializes the environment, cleans the output directory,
# retrieves the active design, and orchestrates the hierarchical SystemVerilog generation process.
proc RunSvGeneration {} {
    # Clean the SystemVerilog output directory to ensure a fresh generation.
    puts "Ensured clean '$::outputDir' directory for new generation."
    if {[file isdirectory $::outputDir]} {
        puts "Cleaning existing '$::outputDir' directory..."
        if {[catch {
            set files_to_delete [glob -nocomplain -directory $::outputDir *]
            foreach f $files_to_delete {
                file delete -force -- $f
            }
        }]} {
            puts "Warning: Could not fully clean existing output directory."
        }
    }
    # Create the output directory if it does not exist.
    if {[catch {file mkdir $::outputDir}]} {
        puts "Error: Could not create output directory '$::outputDir'."
        return
    }
    # Open debug log file
    if {[catch {set ::debugFileHandle [open "$::outputDir/debug.txt" "w"]} err]} {
        puts "Error: Could not open debug.txt for writing: $err"
        return
    }
    
    # Check for an active DboSession (Cadence Capture environment).
    if {![info exists ::DboSession_s_pDboSession]} {
        puts "Error: DboSession not found. Ensure a design is open and the script is run in the correct context."
        close $::debugFileHandle ; # Ensure file is closed on error
        return
    }
    set lSession $::DboSession_s_pDboSession
    DboSession -this $lSession
    set status [DboState]
    
    # Attempt to get the active design from the DboSession.
    set lDesign [$lSession GetActiveDesign]
    if {$lDesign == "NULL"} {
        puts "Error: No active design found. Please open a design before running the script."
        close $::debugFileHandle ; # Ensure file is closed on error
        return
    }

    # Initialize the global array to track processed pages, preventing redundant processing.
    foreach k [array names ::gProcessedPages] {
        unset ::gProcessedPages($k)
    }

    # Retrieve the root schematic of the active design.
    set lRootSchematic [$lDesign GetRootSchematic $status]
    if {$lRootSchematic != "NULL"} {
        print_debug "Root schematic is valid. Starting page collection."
        puts "Starting SystemVerilog generation..."

        # Collect all pages belonging to the root schematic.
        # These pages serve as the initial starting points for the hierarchical traversal.
        set pagesList {}
        if {![catch {$lRootSchematic NewPagesIter $status} lPagesIter]} {
            set lPage [$lPagesIter NextPage $status]
            while {$lPage != "NULL"} {
                lappend pagesList $lPage
                set lPage [$lPagesIter NextPage $status]
            }
            delete_DboSchematicPagesIter $lPagesIter
        }
        print_debug "Number of root pages found: [llength $pagesList]"
        
        # Start the hierarchical traversal for each page found in the root schematic.
        foreach lPage $pagesList {
            TraverseAndGenerate $lPage $lDesign
        }

        puts "SystemVerilog generation complete."
    } else {
        puts "Error: Could not retrieve the root schematic from the active design. Ensure it exists."
    }
    close $::debugFileHandle
}
# --- Main Execution ---
# Call the main procedure to begin the SystemVerilog generation process.
RunSvGeneration
