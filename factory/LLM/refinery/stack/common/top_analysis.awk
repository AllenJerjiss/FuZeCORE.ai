# top_analysis.awk - Generate top performance analysis

@include "variant_analysis.awk"

BEGIN { 
    FS = ","
    AP = ENVIRON["ALIAS_PREFIX"]
    STK = ENVIRON["STACK"]
    TOPN = ENVIRON["TOPN"]
}

# Read baseline data from first pass
FNR == NR && NF > 1 {
    key = $2 "|" $5  # endpoint|model
    baseline[key] = $12 + 0
    next
}

# Process main data
FNR != NR && NR > 1 && $12 + 0 > 0 {
    st = $3
    ep = ($9 != "") ? $9 : $8
    ng = ($12 + 0)
    gl = $10
    va = variant($4, ng, gl, st)
    
    key = $2 "|" $5
    base_tokps = baseline[key]
    
    gain = (base_tokps > 0) ? ($12 + 0) / base_tokps : 0
    
    # Store for sorting
    lines[NR] = sprintf("%s|%s|%s|%s|%.2f|%.2f|%.2f", 
                       htime($1), va, HOST "/" ep, $12, base_tokps, gain)
    scores[NR] = $12 + 0
}

END {
    # Sort by score descending
    n = asorti(scores, indices, "@val_num_desc")
    
    print "| timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
    print "|---------------------|------------------------------------------|-------------------------------------------|---------|----------|------------------|"
    
    count = 0
    for (i = 1; i <= n && count < TOPN; i++) {
        idx = indices[i]
        if (scores[idx] > 0) {
            split(lines[idx], parts, "|")
            printf "| %-19s | %-40s | %-41s | %7s | %8s | %16s |\n",
                   parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
            count++
        }
    }
}