require "xcodeproj"

project_path = File.expand_path("../Apple/UPasswords.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
target_attributes = project.root_object.attributes["TargetAttributes"]

%w[UPasswords-macOS UPasswordsCredentialProvider].each do |target_name|
  target = project.targets.find { |candidate| candidate.name == target_name }
  abort "Missing Xcode target: #{target_name}" unless target

  attributes = target_attributes[target.uuid] ||= {}
  capabilities = attributes["SystemCapabilities"] ||= {}
  capabilities["com.apple.ApplicationGroups.macOS"] = { "enabled" => 1 }
end

project.save
