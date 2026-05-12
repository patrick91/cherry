- nice to have, restore the older convo automatically after closing the terminal

- better icons
› cherry://project/5c1f806f5b1ed688b6abefc6926fb800fcc1369dd6fd32f3276c422860927849/todo/859EE905-D9CF-4C89-91C8-58617E03D4C7

  take a look at this, how much work is it? and is it worth doing, we also don't have ci for it on github yet but I could setup a custom runner


• I’ll inspect the linked Cherry todo first, then check the repo shape around the affected area so I can estimate effort against the actual code rather than guessing.

• Ran pwd && rg --files -g 'AGENTS.md' -g 'README*' -g 'pyproject.toml' -g 'Package.swift' -g '*.xcodeproj' -g '*.xcworkspace' -g '.github/**' | head -200
  └ /Users/patrick/github/farbun-dev/shot
    AGENTS.md
    … +6 lines (ctrl + t to view transcript)
    backend/.pytest_cache/README.md
    backend/.fastapicloud/README.md

• Called cherry.list_todos({})
  └ {"active_project_root": "/Users/patrick/github/farbun-dev/shot", "todos": [{"comment_count": 0, "created_at": 799840880, "id": "76578351-128D-4AF3-87AE-4D75AB82B36B", "link":
        "cherry://project/5c1f806f5b1ed688b6abefc6926fb800fcc1369dd6fd32f3276c422860927849/todo/76578351-128D-4AF3-87AE-4D75AB82B36B", "position": 0, "project_root": "/Users/patrick/github/farbun-dev/shot", "status": "backlog", "tags": [{"color_hex": "#D73A49",
        "id": "admin", "name": "admin"}, {"color_hex": "#6F42C1", "id": "moderation", "name": "moderation"}], "title": "Build admin moderation queue for reports and blocks", "updated_at": 800047270}, {"comment_count": 0, "created_at": 799840880, "id": "D0A9862
        E-2BA2-48D5-B495-E6337AD85F68", "link": "cherry://project/5c1f806f5b1ed688b6abefc6926fb800fcc1369dd6fd32f3276c422860927849/todo/D0A9862E-2BA2-48D5-B495-E6337AD85F68", "position": 1, "project_root": "/Users/patrick/github/farbun-dev/shot", "status": "ba
        cklog", "tags": [{"color_hex": "#0086B3", "id": "backend", "name": "backend"}, {"color_hex": "#735C0F", "id": "iap", "name": "iap"}, {"color_hex": "#0366D6", "id": "security", "name": "security"}], "title": "Review App Store certificate validation and
        production StoreKit setup", "updated_at": 800047270}, {"comment_count": 0, "created_at": 799...

this should call a tool to just get the single todo?
