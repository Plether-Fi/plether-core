#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_arg="${DOCS_OUTPUT_DIR:-docs/book}"
repository_url="${DOCS_REPOSITORY_URL:-https://github.com/Plether-Fi/plether-core}"
revision="${DOCS_REVISION:-$(git -C "${repo_root}" rev-parse HEAD)}"
packages=(shared spot options perps)

if [[ "${output_arg}" == /* ]]; then
    output_dir="${output_arg}"
else
    output_dir="${repo_root}/${output_arg}"
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_root="${tmp_root%/}"
staging_dir="$(mktemp -d "${tmp_root}/plether-docs.XXXXXX")"
site_dir="${staging_dir}/site"

cleanup() {
    if [[ "${staging_dir}" == "${tmp_root}"/plether-docs.* ]]; then
        rm -rf -- "${staging_dir}"
    fi
}
trap cleanup EXIT

mkdir -p "${site_dir}"

for package in "${packages[@]}"; do
    case "${package}" in
        shared) package_title="Shared" ;;
        spot) package_title="Spot" ;;
        options) package_title="Options" ;;
        perps) package_title="Perps" ;;
    esac

    package_out="${staging_dir}/${package}"
    package_home="${staging_dir}/${package}-home.md"

    printf '# Plether %s Contracts\n\n' "${package_title}" > "${package_home}"
    printf 'Package-scoped NatSpec reference generated from `%s` at revision `%s`.\n\n' \
        "packages/${package}/src" "${revision}" >> "${package_home}"
    printf -- '- [Browse the generated API](packages/%s/src/)\n' "${package}" >> "${package_home}"
    printf -- '- [Read the package guide](%s/blob/%s/packages/%s/README.md)\n' \
        "${repository_url}" "${revision}" "${package}" >> "${package_home}"
    printf -- '- [Inspect the package source](%s/tree/%s/packages/%s/src)\n' \
        "${repository_url}" "${revision}" "${package}" >> "${package_home}"

    (
        cd "${repo_root}"
        FOUNDRY_PROFILE=docs \
            FOUNDRY_SRC="packages/${package}/src" \
            FOUNDRY_TEST=.docs-empty/test \
            FOUNDRY_SCRIPT=.docs-empty/script \
            FOUNDRY_DOC_HOMEPAGE="${package_home}" \
            forge doc --out "${package_out}" --build
    )

    package_book="${package_out}/book"

    # Foundry emits source-tree links from the site root. Each package book is
    # mounted below its package name, so make those links relative to the page
    # that contains them. mdBook's print page also prefixes root-relative links
    # with the current chapter path; collapse that generated double path.
    while IFS= read -r -d '' html_file; do
        relative_file="${html_file#"${package_book}/"}"
        parent_dir="${relative_file%/*}"
        link_prefix=""

        if [[ "${parent_dir}" != "${relative_file}" ]]; then
            IFS='/' read -r -a parent_parts <<< "${parent_dir}"
            for _ in "${parent_parts[@]}"; do
                link_prefix="../${link_prefix}"
            done
        fi

        sed -E \
            -e "s|href=\"/packages/${package}|href=\"${link_prefix}packages/${package}|g" \
            -e "s|href=\"[^\"]*//packages/${package}|href=\"packages/${package}|g" \
            "${html_file}" > "${html_file}.tmp"
        mv "${html_file}.tmp" "${html_file}"
    done < <(find "${package_book}" -type f -name '*.html' -print0)

    test -s "${package_book}/index.html"
    test -s "${package_book}/packages/${package}/src/index.html"

    mkdir -p "${site_dir}/${package}"
    cp -R "${package_book}/." "${site_dir}/${package}/"
done

sed \
    -e "s|__REPOSITORY_URL__|${repository_url}|g" \
    -e "s|__REVISION__|${revision}|g" \
    "${repo_root}/.github/pages/index.html" > "${site_dir}/index.html"
touch "${site_dir}/.nojekyll"

if [[ -z "${output_dir}" || "${output_dir}" == "/" || "${output_dir}" == "${repo_root}" ]]; then
    echo "Refusing to replace unsafe documentation output path: ${output_dir}" >&2
    exit 1
fi
if [[ "${output_dir}" != "${repo_root}/docs/book" && "${output_dir}" != /tmp/* \
    && "${output_dir}" != "${tmp_root}"/* ]]; then
    echo "Documentation output must be docs/book or a temporary directory: ${output_dir}" >&2
    exit 1
fi

rm -rf -- "${output_dir}"
mkdir -p "$(dirname "${output_dir}")"
cp -R "${site_dir}" "${output_dir}"

test -s "${output_dir}/index.html"
for package in "${packages[@]}"; do
    test -s "${output_dir}/${package}/index.html"
    test -s "${output_dir}/${package}/packages/${package}/src/index.html"
done

echo "Documentation site assembled at ${output_dir}"
