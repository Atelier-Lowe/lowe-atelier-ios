Pod::Spec.new do |s|
  s.name           = 'LoweRoomPlan'
  s.version        = '1.0.0'
  s.summary        = 'Scan RoomPlan avec photos pour Löwe Atelier'
  s.description    = 'Scan RoomPlan avec photos et positions du téléphone (d après expo-roomplan, MIT)'
  s.license        = 'MIT'
  s.author         = 'Atelier Löwe'
  s.homepage       = 'https://github.com/Atelier-Lowe/lowe-atelier-ios'
  s.platforms      = { :ios => '17.0' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/Atelier-Lowe/lowe-atelier-ios' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.frameworks = 'RoomPlan', 'RealityKit', 'ARKit', 'CoreImage', 'CoreBluetooth'
  s.source_files = "**/*.{h,m,mm,swift}"
end
