#!/usr/bin/env bash
#
# triage.sh <report-file>
#
# Collapse a raw findings report (the tab-separated FINDING lines emitted by
# oracle.sh / run.sh) into a ranked list of distinct bug signatures. Many corpus
# files trip the same underlying bug, so this groups by category plus a
# normalised error message (digits, hex and temp paths blanked) and shows, per
# signature, the count and one concrete example file to start debugging from.

src="${1:?usage: triage.sh <report-file>}"

awk -F'\t' '
  $1 == "FINDING" {
    cat=$2; sev=$3; file=$4; detail=$5
    # Normalise volatile bits so the same bug collapses to one signature.
    sig=detail
    gsub(/0x[0-9a-fA-F]+/, "0xN", sig)
    gsub(/[0-9]+/, "N", sig)
    gsub(/\/tmp\/[^ ]*/, "<tmp>", sig)
    key=cat "\t" sev "\t" sig
    count[key]++
    if (!(key in example)) example[key]=file
  }
  END {
    for (k in count) printf "%6d\t%s\t%s\n", count[k], k, example[k]
  }
' "$src" | sort -rn | awk -F'\t' '
  BEGIN {
    printf "%-6s  %-14s  %-7s  %s\n", "COUNT", "CATEGORY", "SEV", "SIGNATURE"
    printf "%-6s  %-14s  %-7s  %s\n", "-----", "--------", "---", "---------"
  }
  { printf "%-6s  %-14s  %-7s  %s\n          example: %s\n", $1, $2, $3, $4, $5 }
'
