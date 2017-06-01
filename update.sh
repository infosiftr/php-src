#!/bin/bash
set -e

declare -A gpgKeys=(
	# https://wiki.php.net/todo/php71
	# davey & krakjoe
	# https://secure.php.net/downloads.php#gpg-7.1
	[7.1]='A917B1ECDA84AEC2B568FED6F50ABC807BD5DCD0 528995BFEDFBA7191D46839EF9BA0ADA31CBD89E'

	# https://wiki.php.net/todo/php70
	# ab & tyrael
	# https://secure.php.net/downloads.php#gpg-7.0
	[7.0]='1A4E8B7277C42E53DBA9C7B9BCAA30EA9C0D5763 6E4F6AB321FDC07F2C332E3AC2BF0BC433CFC8B3'

	# https://wiki.php.net/todo/php56
	# jpauli & tyrael
	# https://secure.php.net/downloads.php#gpg-5.6
	[5.6]='0BD78B5F97500D450838F95DFE857D9A90D90EC1 6E4F6AB321FDC07F2C332E3AC2BF0BC433CFC8B3'
)
# see https://secure.php.net/downloads.php

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

	EOH
}

travisEnv=
for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"

	# scrape the relevant API based on whether we're looking for pre-releases
	apiUrl="https://secure.php.net/releases/index.php?json&max=100&version=${rcVersion%%.*}"
	apiJqExpr='
		(keys[] | select(startswith("'"$rcVersion"'."))) as $version
		| [ $version, (
			.[$version].source[]
			| select(.filename | endswith(".xz"))
			|
				"https://secure.php.net/get/" + .filename + "/from/this/mirror",
				"https://secure.php.net/get/" + .filename + ".asc/from/this/mirror",
				.sha256 // "",
				.md5 // ""
		) ]
	'
	if [ "$rcVersion" != "$version" ]; then
		apiUrl='https://qa.php.net/api.php?type=qa-releases&format=json'
		apiJqExpr='
			.releases[]
			| select(.version | startswith("7.1."))
			| [
				.version,
				.files.xz.path // "",
				"",
				.files.xz.sha256 // "",
				.files.xz.md5 // ""
			]
		'
	fi
	IFS=$'\n'
	possibles=( $(
		curl -fsSL "$apiUrl" \
			| jq --raw-output "$apiJqExpr | @sh" \
			| sort -rV
	) )
	unset IFS

	if [ "${#possibles[@]}" -eq 0 ]; then
		echo >&2
		echo >&2 "error: unable to determine available releases of $version"
		echo >&2
		exit 1
	fi

	# format of "possibles" array entries is "VERSION URL.TAR.XZ URL.TAR.XZ.ASC SHA256 MD5" (each value shell quoted)
	#   see the "apiJqExpr" values above for more details
	eval "possi=( ${possibles[0]} )"
	fullVersion="${possi[0]}"
	url="${possi[1]}"
	ascUrl="${possi[2]}"
	sha256="${possi[3]}"
	md5="${possi[4]}"

	gpgKey="${gpgKeys[$rcVersion]}"
	if [ -z "$gpgKey" ]; then
		echo >&2 "ERROR: missing GPG key fingerprint for $version"
		echo >&2 "  try looking on https://secure.php.net/downloads.php#gpg-$version"
		exit 1
	fi

	# if we don't have a .asc URL, let's see if we can figure one out :)
	if [ -z "$ascUrl" ] && wget -q --spider "$url.asc"; then
		ascUrl="$url.asc"
	fi

	dockerfiles=()

	{ generated_warning; cat Dockerfile-debian.template; } > "$version/Dockerfile"
	cp -v \
		docker-php-entrypoint \
		docker-php-ext-* \
		docker-php-source \
		"$version/"
	dockerfiles+=( "$version/Dockerfile" )

	if [ -d "$version/raspbian" ]; then
		{ generated_warning; cat Dockerfile-raspbian.template; } > "$version/raspbian/Dockerfile"
		cp -v \
			docker-php-entrypoint \
			docker-php-ext-* \
			docker-php-source \
			"$version/raspbian/"
		dockerfiles+=( "$version/raspbian/Dockerfile" )
	fi

	if [ -d "$version/alpine" ]; then
		{ generated_warning; cat Dockerfile-alpine.template; } > "$version/alpine/Dockerfile"
		cp -v \
			docker-php-entrypoint \
			docker-php-ext-* \
			docker-php-source \
			"$version/alpine/"
		dockerfiles+=( "$version/alpine/Dockerfile" )
	fi

	if [ -d "$version/apache-alpine" ]; then
		{ generated_warning; cat Dockerfile-alpine.template; } > "$version/apache-alpine/Dockerfile"
		cp -v \
			docker-php-entrypoint \
			docker-php-ext-* \
			docker-php-source \
			"$version/apache-alpine/"
		dockerfiles+=( "$version/apache-alpine/Dockerfile" )
	fi

	for target in \
		apache apache/apache-alpine apache/raspbian \
		fpm fpm/alpine fpm/raspbian \
		zts zts/alpine fpm/raspbian \
	; do
		[ -d "$version/$target" ] || continue
		base="$version/Dockerfile"
		variant="${target%%/*}"
		if [ "$target" != "$variant" ]; then
			variantVariant="${target#$variant/}"
			[ -d "$version/$variantVariant" ] || continue
			base="$version/$variantVariant/Dockerfile"
		fi
		echo "Generating $version/$target/Dockerfile from $base + $variant-Dockerfile-block-*"
		awk '
			$1 == "##</autogenerated>##" { ia = 0 }
			!ia { print }
			$1 == "##<autogenerated>##" { ia = 1; ab++; ac = 0 }
			ia { ac++ }
			ia && ac == 1 { system("cat '$variant'-Dockerfile-block-" ab) }
		' "$base" > "$version/$target/Dockerfile"
		cp -v \
			docker-php-entrypoint \
			docker-php-ext-* \
			docker-php-source \
			"$version/$target/"
		dockerfiles+=( "$version/$target/Dockerfile" )
	done

	(
		set -x
		sed -ri \
			-e 's!%%PHP_VERSION%%!'"$fullVersion"'!' \
			-e 's!%%GPG_KEYS%%!'"$gpgKey"'!' \
			-e 's!%%PHP_URL%%!'"$url"'!' \
			-e 's!%%PHP_ASC_URL%%!'"$ascUrl"'!' \
			-e 's!%%PHP_SHA256%%!'"$sha256"'!' \
			-e 's!%%PHP_MD5%%!'"$md5"'!' \
			"${dockerfiles[@]}"
	)

	# update entrypoint commands
	for dockerfile in "${dockerfiles[@]}"; do
		cmd="$(awk '$1 == "CMD" { $1 = ""; print }' "$dockerfile" | tail -1 | jq --raw-output '.[0]')"
		entrypoint="$(dirname "$dockerfile")/docker-php-entrypoint"
		sed -i 's! php ! '"$cmd"' !g' "$entrypoint"
	done

	newTravisEnv=
	for dockerfile in "${dockerfiles[@]}"; do
		dir="${dockerfile%Dockerfile}"
		dir="${dir%/}"
		variant="${dir#$version}"
		variant="${variant#/}"
		newTravisEnv+='\n  - VERSION='"$version VARIANT=$variant"
	done
	travisEnv="$newTravisEnv$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
