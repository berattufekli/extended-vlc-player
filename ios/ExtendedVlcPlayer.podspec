require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExtendedVlcPlayer'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = 'MIT'
  s.author         = 'bbStudio'
  s.homepage       = 'https://github.com/berattufekli/iptv_expo'
  s.platforms      = {
    :ios => '16.4',
    :tvos => '16.4'
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/berattufekli/iptv_expo' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.dependency 'MobileVLCKit', '~> 3.7.0'

  s.source_files = '**/*.{h,m,mm,swift}'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_OBJC_INTERFACE_HEADER_NAME' => 'ExtendedVlcPlayer-Swift.h',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -D COCOAPODS -Xfrontend -module-name -Xfrontend ExtendedVlcPlayer',
    # The host app's Podfile already enables use_frameworks! :linkage => :static
    # so we keep this pod consistent with that mode.
  }
end
