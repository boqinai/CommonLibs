# Aliyun 融合认证 (fusion auth) iOS bridge for Boqinai Flutter apps.
# Vendors fusionAuthSDK_APP_iOS v1.2.15 (AlicomFusionAuth.xcframework, a
# dynamic framework, min iOS 15.0) and its resource bundles. Umeng is not
# bundled: the SDK does not link it (only NSClassFromString lookups).
Pod::Spec.new do |s|
  s.name             = 'fusion_auth'
  s.version          = '0.3.1'
  s.summary          = 'Aliyun fusion auth bridge for Boqinai Flutter apps.'
  s.description      = 'Runs the Aliyun 融合认证 template and returns its verify token to Dart.'
  s.homepage         = 'https://github.com/boqinai/CommonLibs/tree/main/fusion_auth'
  s.license          = { :type => 'Proprietary', :text => 'Aliyun SDK; see Aliyun terms.' }
  s.author           = { 'Boqinai' => 'dev@boqinai.invalid' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'

  s.source_files        = 'Classes/**/*.{h,m,c}'
  s.public_header_files = 'Classes/FusionAuthPlugin.h'
  s.dependency 'Flutter'

  s.vendored_frameworks = 'Frameworks/AlicomFusionAuth.xcframework'
  s.resources        = ['Resources/ATAuthSDK.bundle', 'Resources/AlicomCaptcha4.bundle']

  s.frameworks = 'CoreTelephony', 'SystemConfiguration', 'Network', 'WebKit', 'CFNetwork', 'Security'
  s.libraries  = 'sqlite3'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
