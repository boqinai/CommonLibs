Pod::Spec.new do |s|
  s.name = 'carrier_auth'
  s.version = '0.1.0'
  s.summary = 'Standalone Aliyun carrier authorization for Flutter.'
  s.description = 'Returns an explicitly authorized carrier token; backend login belongs to the host.'
  s.homepage = 'https://github.com/boqinai/CommonLibs/tree/main/carrier_auth'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'Boqinai' => 'dev@boqinai.invalid' }
  s.source = { :path => '.' }
  s.platform = :ios, '15.0'
  s.source_files = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/CarrierAuthPlugin.h'
  s.dependency 'Flutter'
  # The framework already embeds the documented standalone carrier SDK.
  s.dependency 'fusion_auth', '0.3.6'
  s.frameworks = 'UIKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
