#!/usr/bin/env bash
# Stage a writable symlink-backed view of the read-only host npm _cacache
# when EZGHA_NPM_CACHE is mounted, so `npm ci` hits local tarballs offline
# and still succeeds without EROFS on cache misses. Fails open on any error.
if [ -n "${EZGHA_NPM_CACHE:-}" ] && [ -d "${EZGHA_NPM_CACHE}/_cacache" ] && [ -z "${NPM_CONFIG_CACHE:-}" ]; then
  stage_dir="/tmp/ezgha-npm-cache"
  if [ ! -f "${stage_dir}/_cacache/.ezgha-staged" ]; then
    tmp_stage="${stage_dir}.tmp.$$"
    rm -rf "${tmp_stage}" 2>/dev/null || true
    if (
      set -e
      mkdir -p "${tmp_stage}/_cacache"
      if [ -d "${EZGHA_NPM_CACHE}/_cacache/index-v5" ]; then
        cp -a "${EZGHA_NPM_CACHE}/_cacache/index-v5" "${tmp_stage}/_cacache/"
        chmod -R u+rwX "${tmp_stage}/_cacache/index-v5"
      fi
      if [ -d "${EZGHA_NPM_CACHE}/_cacache/content-v2" ]; then
        cp -rs "${EZGHA_NPM_CACHE}/_cacache/content-v2" "${tmp_stage}/_cacache/"
      fi
      find "${tmp_stage}/_cacache" -type d -exec chmod u+rwx {} +
      touch "${tmp_stage}/_cacache/.ezgha-staged"
    ) >/dev/null 2>&1; then
      rm -rf "${stage_dir}" 2>/dev/null || true
      mv "${tmp_stage}" "${stage_dir}" 2>/dev/null || rm -rf "${tmp_stage}" 2>/dev/null || true
    else
      rm -rf "${tmp_stage}" 2>/dev/null || true
    fi
  fi
  if [ -f "${stage_dir}/_cacache/.ezgha-staged" ]; then
    export NPM_CONFIG_CACHE="${stage_dir}"
    export NPM_CONFIG_PREFER_OFFLINE=true
    export NPM_CONFIG_UPDATE_NOTIFIER=false
  fi
fi
if [ "$#" -eq 0 ]; then
  set -- /bin/bash
fi
exec "$@"
