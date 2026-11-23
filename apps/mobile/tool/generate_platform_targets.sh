#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required. Install Flutter and add it to PATH." >&2
  exit 1
fi

cd "${APP_DIR}"

# Generate the native runner shells around Breezze's single lib/ codebase.
# Existing Dart source is retained; dependency resolution is intentionally
# left to the caller so this script does not silently update lockfiles.
flutter create \
  --platforms=android,ios,web,linux,macos,windows \
  --project-name=breezze \
  --org=com.breezze \
  --no-pub \
  .


# Configure OS background audio declarations after Flutter generates native runners.
# The repository intentionally keeps one shared Dart app; these are thin native
# service declarations, not separate platform application implementations.
python3 - "${APP_DIR}" <<'PY'
import plistlib
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

app_dir = Path(sys.argv[1])
android_ns = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", android_ns)

manifest_path = app_dir / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
if manifest_path.exists():
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    application = root.find("application")
    if application is None:
        raise SystemExit("AndroidManifest.xml has no <application> element")

    def android_attr(name):
        return "{%s}%s" % (android_ns, name)

    permissions = {
        # Flutter's generated debug manifest can add INTERNET only for debug.
        # Breezze release builds must also reach the authenticated API/CDN.
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.WAKE_LOCK",
    }
    existing_permissions = {
        node.get(android_attr("name"))
        for node in root.findall("uses-permission")
    }
    for permission in sorted(permissions - existing_permissions):
        node = ET.Element("uses-permission")
        node.set(android_attr("name"), permission)
        root.insert(list(root).index(application), node)

    service_name = "com.ryanheise.audioservice.AudioService"
    if not any(node.get(android_attr("name")) == service_name
               for node in application.findall("service")):
        service = ET.SubElement(application, "service")
        service.set(android_attr("name"), service_name)
        service.set(android_attr("foregroundServiceType"), "mediaPlayback")
        service.set(android_attr("exported"), "true")
        intent = ET.SubElement(service, "intent-filter")
        ET.SubElement(intent, "action").set(
            android_attr("name"), "android.media.browse.MediaBrowserService"
        )

    receiver_name = "com.ryanheise.audioservice.MediaButtonReceiver"
    if not any(node.get(android_attr("name")) == receiver_name
               for node in application.findall("receiver")):
        receiver = ET.SubElement(application, "receiver")
        receiver.set(android_attr("name"), receiver_name)
        receiver.set(android_attr("exported"), "true")
        intent = ET.SubElement(receiver, "intent-filter")
        ET.SubElement(intent, "action").set(
            android_attr("name"), "android.intent.action.MEDIA_BUTTON"
        )

    # Supabase OAuth returns to Breezze using its own custom scheme.
    main_activity = next((
        node for node in application.findall("activity")
        if (node.get(android_attr("name")) or "").endswith("MainActivity")
    ), None)
    if main_activity is not None:
        deeplink_found = any(
            data.get(android_attr("scheme")) == "io.breezze.app"
            for filt in main_activity.findall("intent-filter")
            for data in filt.findall("data")
        )
        if not deeplink_found:
            main_activity.set(android_attr("launchMode"), "singleTop")
            intent = ET.SubElement(main_activity, "intent-filter")
            ET.SubElement(intent, "action").set(
                android_attr("name"), "android.intent.action.VIEW")
            ET.SubElement(intent, "category").set(
                android_attr("name"), "android.intent.category.DEFAULT")
            ET.SubElement(intent, "category").set(
                android_attr("name"), "android.intent.category.BROWSABLE")
            data = ET.SubElement(intent, "data")
            data.set(android_attr("scheme"), "io.breezze.app")
            data.set(android_attr("host"), "login-callback")

    tree.write(manifest_path, encoding="utf-8", xml_declaration=True)

# audio_service requires the generated Android Activity to use its
# FlutterEngine-aware base class so notification callbacks reach the app.
kotlin_activity = app_dir / "android" / "app" / "src" / "main" / "kotlin" / "com" / "breezze" / "breezze" / "MainActivity.kt"
if kotlin_activity.exists():
    source = kotlin_activity.read_text()
    source = source.replace(
        "import io.flutter.embedding.android.FlutterActivity",
        "import com.ryanheise.audioservice.AudioServiceActivity",
    ).replace(": FlutterActivity()", ": AudioServiceActivity()")
    kotlin_activity.write_text(source)

java_activity = app_dir / "android" / "app" / "src" / "main" / "java" / "com" / "breezze" / "breezze" / "MainActivity.java"
if java_activity.exists():
    source = java_activity.read_text()
    source = source.replace(
        "import io.flutter.embedding.android.FlutterActivity;",
        "import com.ryanheise.audioservice.AudioServiceActivity;",
    ).replace("extends FlutterActivity", "extends AudioServiceActivity")
    java_activity.write_text(source)

# The current audio_service_win native plugin still includes Microsoft's
# deprecated experimental coroutine header. MSVC 14.52 promotes its
# deprecation to a hard error; silence only this upstream compatibility
# diagnostic for the generated Windows runner until the plugin is updated.
windows_cmake = app_dir / "windows" / "CMakeLists.txt"
if windows_cmake.exists():
    cmake = windows_cmake.read_text()
    definition = "add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)"
    if definition not in cmake:
        project_line = next(
            (line for line in cmake.splitlines()
             if line.strip().startswith("project(")),
            None,
        )
        if project_line is None:
            raise SystemExit("Windows CMakeLists.txt has no project() declaration")
        cmake = cmake.replace(
            project_line,
            project_line + "\n" + definition,
            1,
        )
        windows_cmake.write_text(cmake)

linux_runner = app_dir / "linux" / "runner" / "my_application.cc"
if linux_runner.exists():
    source = linux_runner.read_text()
    anchor = "  g_autoptr(FlDartProject) project = fl_dart_project_new();"
    if "gtk_window_set_icon_from_file" not in source:
        if anchor not in source:
            raise SystemExit("Cannot locate Linux runner initialization")
        source = source.replace(anchor, anchor + """
  const gchar* assets = fl_dart_project_get_assets_path(project);
  g_autofree gchar* icon = g_build_filename(assets, "assets", "icons", "launcher.png", nullptr);
  gtk_window_set_icon_from_file(window, icon, nullptr);
  gtk_window_set_title(window, "Breezze");""")
        linux_runner.write_text(source)

ios_plist = app_dir / "ios" / "Runner" / "Info.plist"
if ios_plist.exists():
    with ios_plist.open("rb") as source:
        values = plistlib.load(source)
    schemes = values.setdefault("CFBundleURLTypes", [])
    breezze_scheme = "io.breezze.app"
    if not any(
        breezze_scheme in item.get("CFBundleURLSchemes", [])
        for item in schemes
    ):
        schemes.append({
            "CFBundleTypeRole": "Editor",
            "CFBundleURLSchemes": [breezze_scheme],
        })
    reversed_client_id = os.environ.get("GOOGLE_IOS_REVERSED_CLIENT_ID", "")
    if reversed_client_id and not any(
        reversed_client_id in item.get("CFBundleURLSchemes", [])
        for item in schemes
    ):
        schemes.append({
            "CFBundleTypeRole": "Editor",
            "CFBundleURLSchemes": [reversed_client_id],
        })
    modes = values.setdefault("UIBackgroundModes", [])
    if "audio" not in modes:
        modes.append("audio")
    with ios_plist.open("wb") as target:
        plistlib.dump(values, target)

# A sandboxed macOS release must explicitly permit outbound HTTPS streams.
# Keep the native entitlement files generated by Flutter, changing only this
# one network entitlement and preserving their existing security settings.
for entitlement_name in ("DebugProfile.entitlements", "Release.entitlements"):
    entitlement_path = app_dir / "macos" / "Runner" / entitlement_name
    if not entitlement_path.exists():
        continue
    with entitlement_path.open("rb") as source:
        entitlements = plistlib.load(source)
    if os.environ.get("BREEZZE_APPLE_SIGN_IN_ENABLED") == "1":
        entitlements["com.apple.developer.applesignin"] = ["Default"]
    entitlements["com.apple.security.network.client"] = True
    entitlements["com.apple.security.files.user-selected.read-only"] = True
    with entitlement_path.open("wb") as target:
        plistlib.dump(entitlements, target)

if os.environ.get("BREEZZE_APPLE_SIGN_IN_ENABLED") == "1":
    ios_entitlements = app_dir / "ios" / "Runner" / "Runner.entitlements"
    with ios_entitlements.open("wb") as target:
        plistlib.dump({"com.apple.developer.applesignin": ["Default"]}, target)
    project_file = app_dir / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if project_file.exists():
        contents = project_file.read_text()
        if "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;" not in contents:
            contents = re.sub(
                r"(?m)^(\\s*)PRODUCT_BUNDLE_IDENTIFIER = com\\.breezze\\.breezze;",
                lambda m: m.group(1) +
                    "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\\n" +
                    m.group(0),
                contents,
            )
            project_file.write_text(contents)

print("Configured release networking, media service and Supabase sign-in callbacks.")

PY
