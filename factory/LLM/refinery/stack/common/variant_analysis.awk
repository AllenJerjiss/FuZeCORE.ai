# variant_analysis.awk - Extract variant analysis logic from analyze.sh

function aliasify(s,  t) {
    t = s
    gsub(/[\/:]+/, "-", t)
    return t
}

function trim_lead_dash(s) { 
    gsub(/^-+/, "", s)
    return s 
}

function variant(base, ng, gl, st,  ab, sfx, sfx2, va) {
    ab = aliasify(base)
    sfx = ENVIRON["ALIAS_SUFFIX"]
    sfx2 = trim_lead_dash(sfx)
    if (sfx2 != "")
        va = sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab)
    else
        va = sprintf("%s%s-%s-%s", AP, st, gl, ab)
    if (ng + 0 > 0)
        va = va "+ng" ng
    return va
}

function htime(ts) {
    return (length(ts) >= 15) ? 
        sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4), substr(ts,5,2), substr(ts,7,2), 
                substr(ts,10,2), substr(ts,12,2), substr(ts,14,2)) : ts
}