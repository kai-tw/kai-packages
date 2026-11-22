#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint keychain.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'keychain'
  s.version          = '0.1.0'
  s.summary          = 'A local key store backed by the iOS Keychain.'
  s.description      = <<-DESC
Creates, reads and deletes 256-bit keys stored as WhenUnlockedThisDeviceOnly
Keychain items behind a platform channel, and reports whether protected data
is available right now.
                       DESC
  s.homepage         = 'https://github.com/kai-tw/kai-packages/tree/main/packages/keychain'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Kai' => 'wuvincentck505@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'keychain/Sources/keychain/**/*.swift'
  s.dependency 'Flutter'
  # Flutter's own current floor, not something this package's native code
  # needs.
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'keychain_privacy' => ['keychain/Sources/keychain/PrivacyInfo.xcprivacy']}
end
