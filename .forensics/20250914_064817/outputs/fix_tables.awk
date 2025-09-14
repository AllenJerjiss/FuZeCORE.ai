function trim(s){ sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function repeat(ch, n,   r,i){ r=""; for(i=0;i<n;i++) r=r ch; return r }
function print_table(rows, nrows,   i,j,ncols, w, hdr_idx, is_sep, hdr_seen, row, coltxt) {
  if (nrows==0) return
  # Identify header block (first three lines if they look like border/name/border)
  hdr_idx = 0
  if (nrows>=3 && rows[1] ~ /^\|[-: ]+\|$/ && rows[2] ~ /^\|[[:space:]]*timestamp[[:space:]]*\|/ && rows[3] ~ /^\|[-: ]+\|$/) {
    hdr_idx = 2  # header text row
  }
  # Parse all rows into fields
  split("", cols); split("", widths)
  ncols = 0
  # First pass: compute widths from DATA rows (skip duplicate header blocks)
  for (i=1;i<=nrows;i++) {
    row = rows[i]
    if (row ~ /^\|[-: ]+\|$/) continue # borders don't affect widths
    if (i==2 && hdr_idx==2) continue   # skip header text for widths
    # split by '|'
    nf = split(row, parts, /\|/)
    # parts[1] and parts[nf] are empty around edges; normalize columns (2..nf-1)
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      if (j-1 > ncols) ncols = j-1
      len = length(coltxt)
      if (len > widths[j-1]) widths[j-1] = len
      data[i, j-1] = coltxt
    }
  }
  # Second pass: print header (once), then data rows aligned
  # Build border based on widths
  border="|"
  for (j=1;j<=ncols;j++) border = border repeat("-", widths[j] + 2) "|"
  print border
  # Header row: if we detected one, use its cells; else synthesize from second line if present
  if (hdr_idx==2) {
    nf = split(rows[2], parts, /\|/)
    out="|"
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      pad = widths[j-1] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  } else {
    # No header detected: synthesize generic numbered headers
    out="|"
    for (j=1;j<=ncols;j++) {
      coltxt = "col" j
      pad = widths[j] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  }
  print border
  # Now print only data lines (skip any duplicate header lines encountered)
  for (i=1;i<=nrows;i++) {
    row = rows[i]
    if (row ~ /^\|[-: ]+\|$/) continue
    if (i==2 && hdr_idx==2) continue
    nf = split(row, parts, /\|/)
    out="|"
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      pad = widths[j-1] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  }
}
# Main: accumulate contiguous '|' blocks; any other lines flush the current table
{
  if ($0 ~ /^\|/) {
    tbl[++nrows] = $0
    pending=1
  } else {
    if (pending) { print_table(tbl, nrows); delete tbl; nrows=0; pending=0 }
    print $0
  }
}
END{
  if (pending) { print_table(tbl, nrows) }
}
