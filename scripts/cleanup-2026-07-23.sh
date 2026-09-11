#!/bin/bash
# Cleanup script for /Volumes/AiOS Repository/code
# Generated 2026-07-23 by Perplexity Computer — review before running.
# Run with: bash "scripts/cleanup-2026-07-23.sh" from the repo root, or
#   bash "/Volumes/AiOS Repository/code/scripts/cleanup-2026-07-23.sh"
#
# What this does (all items already reviewed/approved):
#   1. Removes .DS_Store files (root + all sub-repos, including inside .git/)
#   2. Removes AiOSCore/.build and AiOSOrchestrator/.build (SPM build cache, ~282MB, regenerates on next build)
#   3. Removes the stale aicode-auto.log (tool-run log)
#   4. Removes the loose root-level AiOSCore.swift (already archived to
#      _archive/AiOSCore-swiftdata-prototype.swift.bak — safe to delete original)
#   5. Untracks (git rm --cached, keeps file on disk) the 3 accidentally-committed
#      xcuserdata/xcschememanagement.plist files in AiOSBusiness, AiOSHub, AiOSMyFamily
#      (now covered by the .gitignore files just added to each repo)
#   6. Removes a small leftover .cleanup-write-test.tmp probe file from this session

set -euo pipefail
cd "/Volumes/AiOS Repository/code"

echo "== 1/6: removing .DS_Store files =="
find . -name ".DS_Store" -print -delete

echo "== 2/6: removing SPM .build caches =="
rm -rfv AiOSCore/.build AiOSOrchestrator/.build

echo "== 3/6: removing aicode-auto.log =="
rm -fv aicode-auto.log

echo "== 4/6: removing archived-duplicate loose AiOSCore.swift =="
rm -fv AiOSCore.swift

echo "== 5/6: untracking committed xcuserdata files =="
( cd AiOSBusiness && git rm --cached -q "AiOSBusiness.xcodeproj/xcuserdata/timjohnson.xcuserdatad/xcschemes/xcschememanagement.plist" && echo "  AiOSBusiness: untracked" )
( cd AiOSHub && git rm --cached -q "AiOSHub.xcodeproj/xcuserdata/timjohnson.xcuserdatad/xcschemes/xcschememanagement.plist" && echo "  AiOSHub: untracked" )
( cd AiOSMyFamily && git rm --cached -q "AiOSMyFamily.xcodeproj/xcuserdata/timjohnson.xcuserdatad/xcschemes/xcschememanagement.plist" && echo "  AiOSMyFamily: untracked" )

echo "== 6/6: removing leftover probe file =="
rm -fv .cleanup-write-test.tmp

echo "Done. Review 'git status' in AiOSBusiness/AiOSHub/AiOSMyFamily and commit the .gitignore + untrack changes when ready."
