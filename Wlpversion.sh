#!/bin/sh

# Script to check WLP version in POM files
# Works with Alpine + Maven only (no xmllint/xmlstarlet needed)

set -e

# Define what versions are acceptable (latest and latest-1)
LATEST_VERSION="25.0.0.12"
PREVIOUS_VERSION="25.0.0.11"

echo "Checking WLP versions in POM..."
echo "Allowed versions: ${LATEST_VERSION} or ${PREVIOUS_VERSION}"
echo ""

# Function to check if version is valid
is_version_valid() {
    local version=$1
    if [ "$version" = "$LATEST_VERSION" ] || [ "$version" = "$PREVIOUS_VERSION" ]; then
        return 0
    else
        return 1
    fi
}

found_invalid=0
found_any=0

# ===== Method 1: Check Maven properties =====
echo "Checking Maven properties..."
PROPERTIES_TO_CHECK="wlp.version wlpVersion wlp.kernel.version wlpKernelVersion"

for prop in $PROPERTIES_TO_CHECK; do
    version=$(mvn help:evaluate -Dexpression="${prop}" -q -DforceStdout 2>/dev/null || echo "")
    
    if [ -n "$version" ] && [ "$version" != "null" ] && ! echo "$version" | grep -q '^\${'; then
        found_any=1
        echo "Found property <${prop}>: ${version}"
        
        if is_version_valid "$version"; then
            echo "  ✓ Version is valid"
        else
            echo "  ✗ Version is INVALID"
            found_invalid=1
        fi
        echo ""
    fi
done

# ===== Method 2: Direct POM parsing with grep/sed =====
echo "Scanning POM file directly..."

# Find all POM files
find . -name "pom.xml" -type f | while read -r pom_file; do
    echo "Checking: $pom_file"
    
    # Look for patterns like <wlp.version>, <wlpVersion>, <wlp-version>, <wlp-kernel.version>
    # This captures the content between the tags
    grep -E '<(wlp[.-]?version|wlpVersion|wlp[.-]?kernel[.-]?version)>' "$pom_file" 2>/dev/null | \
        sed -E 's/.*<[^>]+>([^<]+)<.*/\1/' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
        while read -r version; do
            found_any=1
            echo "  Found version tag: ${version}"
            
            if is_version_valid "$version"; then
                echo "    ✓ Version is valid"
            else
                echo "    ✗ Version is INVALID"
                found_invalid=1
            fi
        done
    
    # Look for <artifactId>wlp-kernel</artifactId> followed by <version>
    # Use awk to find artifactId and capture the next version tag
    awk '
        /<artifactId>wlp-kernel<\/artifactId>/ {found=1; next}
        found && /<version>/ {
            match($0, /<version>([^<]+)<\/version>/, arr)
            if (arr[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                print arr[1]
            }
            found=0
        }
        /<\/dependency>/ {found=0}
    ' "$pom_file" | while read -r version; do
        found_any=1
        echo "  Found wlp-kernel dependency: ${version}"
        
        if is_version_valid "$version"; then
            echo "    ✓ Version is valid"
        else
            echo "    ✗ Version is INVALID"
            found_invalid=1
        fi
    done
    
    echo ""
done

# ===== Method 3: Check effective POM =====
echo "Checking effective POM for resolved dependencies..."
temp_pom=$(mktemp)
mvn help:effective-pom -Doutput="$temp_pom" -q 2>/dev/null

# Look for wlp-kernel in dependencies
awk '
    /<artifactId>wlp-kernel<\/artifactId>/ {found=1; next}
    found && /<version>/ {
        match($0, /<version>([^<]+)<\/version>/, arr)
        if (arr[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            print arr[1]
        }
        found=0
    }
    /<\/dependency>/ {found=0}
' "$temp_pom" | sort -u | while read -r version; do
    found_any=1
    echo "Found wlp-kernel in effective POM: ${version}"
    
    if is_version_valid "$version"; then
        echo "  ✓ Version is valid"
    else
        echo "  ✗ Version is INVALID"
        found_invalid=1
    fi
    echo ""
done

rm -f "$temp_pom"

# Final result
echo "================================"
if [ $found_any -eq 0 ]; then
    echo "⚠ WARNING: No WLP versions found in POM"
    exit 1
elif [ $found_invalid -eq 1 ]; then
    echo "✗ FAILED: Invalid WLP version(s) detected"
    exit 1
else
    echo "✓ SUCCESS: All WLP versions are valid"
    exit 0
fi
