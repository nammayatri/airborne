Pod::Spec.new do |s|
  s.name             = 'Airborne'
  s.version          = '0.33.0'
  s.summary          = 'An OTA update plugin for Android, iOS and React Native applications.'
  s.description      = <<-DESC
Hyper OTA empowers developers to effortlessly integrate Over-The-Air (OTA) update capabilities into their Android, iOS, and React Native applications.
Our primary focus is to provide robust, easy-to-use SDKs and plugins that streamline the update process directly within your client applications.
                       DESC

  s.homepage         = 'https://github.com/PraveenGongada/airborne'
  s.license          = { :type => 'Apache 2.0', :file => 'LICENSE' }
  s.author           = {
    'MovingTech' => 'sdk@nammayatri.in'
  }

  s.source       = { :http => "https://github.com/PraveenGongada/airborne/releases/download/v#{s.version}/Airborne.xcframework.zip" }
  
  s.ios.vendored_frameworks = "Airborne.xcframework"
  s.platform     = :ios, "12.0"
end