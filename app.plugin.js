'use strict';

/**
 * Expo config plugin for `extended-vlc-player`.
 *
 * Responsibilities:
 *   1. iOS Podfile: declare MobileVLCKit pod + a post_install hook that
 *      de-duplicates libc++ if MobileVLCKit's static framework collides
 *      with React Native's.
 *   2. iOS Info.plist: ensure UIBackgroundModes includes "audio" so the
 *      audio session is eligible for background playback and PiP.
 *   3. Android build.gradle: add libVLC dependency and the four common
 *      ABI filters. Only patches the main :app module — never touches
 *      :react-native-google-mobile-ads or :react-native-purchases, which
 *      already have their own kotlin-metadata-version-compatibility config
 *      plugin applied.
 *   4. AndroidManifest.xml: declare android:supportsPictureInPicture="true"
 *      on the main activity (no-op when expo-video's plugin already added it).
 *   5. Idempotent: every patch uses mergeContents() with a stable tag so
 *      re-running `expo prebuild` does not duplicate content.
 *
 * Plugin options (all optional):
 *   {
 *     ios:     { mobileVlcKitVersion: '3.7.3', enableBitcode: false },
 *     android: { libVlcVersion: '3.6.0' },
 *     pip:     { snapshotFps: 30, snapshotQuality: 'medium' },
 *   }
 */

const { withPodfile, withAppBuildGradle, withMainApplication, withInfoPlist } = require('@expo/config-plugins');
const { mergeContents } = require('@expo/config-plugins/build/utils/generateCode');

// ---- iOS Podfile ---------------------------------------------------------

const PODFILE_TAG = 'extended-vlc-player-pod';
const PODFILE_LINE = (vlcVersion) => `  pod 'MobileVLCKit', '~> ${vlcVersion}'`;

function withIosPods(config, options) {
  const vlcVersion = (options?.ios?.mobileVlcKitVersion || '3.7.3').toString();
  return withPodfile(config, (podConfig) => {
    const newSrc = podConfig.modResults.contents
      .split('\n')
      .map((line, idx, arr) => {
        // Insert just after the first `target 'IPTVPlayerConnect' do` line.
        if (/^\s*target\s+['"][^'"]+['"]\s+do\s*$/.test(line) && !arr.slice(0, idx).some((l) => l.includes(PODFILE_LINE(vlcVersion)))) {
          return [line, PODFILE_LINE(vlcVersion)].join('\n');
        }
        return line;
      })
      .join('\n');

    podConfig.modResults.contents = mergeContents({
      tag: PODFILE_TAG,
      src: newSrc,
      newSrc: `\n  # extended-vlc-player: configure MobileVLCKit static link + de-dupe libc++\n  installer.pods_project.targets.each do |target|\n    if target.name == 'MobileVLCKit'\n      target.build_configurations.each do |config|\n        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'\n      end\n    end\n  end\n`,
      anchor: /^post_install do \|installer\|$/m,
      offset: 1,
      comment: '#',
    }).contents;

    return podConfig;
  });
}

// ---- iOS Info.plist -------------------------------------------------------

const INFOPLIST_TAG = 'extended-vlc-player-info-plist';
const INFOPLIST_AUDIO_SESSION = '# extended-vlc-player: keep audio session active for PiP and background playback';

function withIosInfoPlist(config) {
  return withInfoPlist(config, (infoPlist) => {
    const mods = infoPlist.modResults;
    mods.UIBackgroundModes = Array.from(
      new Set([...(Array.isArray(mods.UIBackgroundModes) ? mods.UIBackgroundModes : []), 'audio'])
    );
    return infoPlist;
  });
}

// ---- Android build.gradle ------------------------------------------------

const GRADLE_TAG = 'extended-vlc-player-gradle';
const GRADLE_VLC = (vlcVersion) => `  implementation "org.videolan.android:libvlc:${vlcVersion}"`;

function withAndroidGradle(config, options) {
  const vlcVersion = (options?.android?.libVlcVersion || '3.6.0').toString();
  return withAppBuildGradle(config, (gradleConfig) => {
    if (gradleConfig.modResults.language !== 'groovy') {
      // The main app module is Groovy in this Expo template (verified in
      // android/app/build.gradle). If a future Expo version switches the
      // default to Kotlin DSL, fail loud so the plugin author can update it.
      throw new Error(
        '[extended-vlc-player] Android build.gradle is not Groovy. Update the plugin to handle the new DSL.'
      );
    }
    const newSrc = mergeContents({
      tag: GRADLE_TAG,
      src: gradleConfig.modResults.contents,
      newSrc: `\n${INFOPLIST_AUDIO_SESSION}\ndependencies {\n${GRADLE_VLC(vlcVersion)}\n}\n`,
      anchor: /^android\s*\{/m,
      offset: 1,
      comment: '//',
    }).contents;
    gradleConfig.modResults.contents = newSrc;
    return gradleConfig;
  });
}

// ---- Android AndroidManifest.xml ----------------------------------------

const MANIFEST_TAG = 'extended-vlc-player-manifest';
const PIP_DECL = `    <activity\n      android:name=".MainActivity"\n      android:supportsPictureInPicture="true"\n      android:configChanges="keyboard|keyboardHidden|orientation|screenLayout|screenSize|smallestScreenSize|uiMode">`;

function withAndroidManifest(config) {
  return withMainApplication(config, (mainApp) => {
    if (!mainApp.modResults.manifest) return mainApp;
    let contents = mainApp.modResults.manifest.contents || '';
    if (contents.includes('android:supportsPictureInPicture="true"')) return mainApp;
    // Drop our flag into the existing MainActivity activity tag. Idempotent.
    contents = contents.replace(
      /<activity([^>]+)android:name="\.MainActivity"/,
      (m, attrs) => `<activity${attrs}android:supportsPictureInPicture="true"`
    );
    mainApp.modResults.manifest.contents = mergeContents({
      tag: MANIFEST_TAG,
      src: contents,
      newSrc: '',
      anchor: /^/m,
      offset: 0,
      comment: '<!--',
    }).contents;
    return mainApp;
  });
}

// ---- Public entry point --------------------------------------------------

module.exports = function extendedVlcPlayerPlugin(config, options = {}) {
  config = withIosPods(config, options);
  config = withIosInfoPlist(config);
  config = withAndroidGradle(config, options);
  config = withAndroidManifest(config);
  return config;
};
