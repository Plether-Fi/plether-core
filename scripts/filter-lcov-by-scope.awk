function include_path(path) {
    is_spot = path ~ /(^|\/)packages\/spot\/src\//
    is_perps = path ~ /(^|\/)packages\/perps\/src\//
    is_options = path ~ /(^|\/)packages\/options\/src\//

    if (scope == "spot" || scope == "core") {
        return is_spot
    }
    if (scope == "perps") {
        return is_perps
    }
    if (scope == "options") {
        return is_options
    }

    print "Unknown coverage scope: " scope > "/dev/stderr"
    exit 2
}

BEGIN {
    if (scope == "") {
        print "coverage scope is required" > "/dev/stderr"
        exit 2
    }
}

/^SF:/ {
    record = $0 ORS
    path = $0
    sub(/^SF:/, "", path)
    include = include_path(path)
    next
}

record != "" {
    record = record $0 ORS
}

/^end_of_record$/ {
    if (include) {
        printf "%s", record
        kept++
    }
    record = ""
    include = 0
}

END {
    if (kept == 0) {
        print "No LCOV records matched coverage scope: " scope > "/dev/stderr"
        exit 1
    }
}
