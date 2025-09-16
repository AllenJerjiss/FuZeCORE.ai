# baseline_map.awk - Create baseline performance mapping

@include "variant_analysis.awk"

BEGIN { 
    FS = ","
    AP = ENVIRON["ALIAS_PREFIX"]
    STK = ENVIRON["STACK"]
}

NR > 1 && $6 == "base-as-is" && $12 + 0 > 0 {
    key = $2 "|" $5  # endpoint|model
    if ($12 + 0 > baseline[key]) {
        baseline[key] = $12 + 0
        baseline_row[key] = $0
    }
}

END {
    for (key in baseline) {
        print baseline_row[key]
    }
}