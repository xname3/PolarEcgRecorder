require 'xcodeproj'

project_path = 'PolarEcgRecorder.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'PolarEcgRecorder' }
group = project.main_group.find_subpath('PolarEcgRecorder', true)

# Remove dead references recursively
def remove_dead_refs(group, target)
  group.children.dup.each do |child|
    if child.class == Xcodeproj::Project::Object::PBXGroup
      remove_dead_refs(child, target)
    elsif child.class == Xcodeproj::Project::Object::PBXFileReference
      if child.path && child.path.end_with?('.swift') && !File.exist?(child.real_path)
        puts "Removing dead ref: #{child.path}"
        # Remove from build phases
        build_file = target.source_build_phase.files.find { |f| f.file_ref == child }
        target.source_build_phase.remove_build_file(build_file) if build_file
        child.remove_from_project
      end
    end
  end
end
remove_dead_refs(group, target)

# Add new files
Dir.glob('PolarEcgRecorder/**/*.swift').each do |file|
  next if file.include?('Tests')
  # Only add if not already in project
  existing = target.source_build_phase.files_references.find { |f| f.real_path.to_s == File.expand_path(file) }
  if existing.nil?
    puts "Adding new file: #{file}"
    # find or create group path
    relative_path = file.sub('PolarEcgRecorder/', '')
    parts = relative_path.split('/')
    filename = parts.pop
    
    current_group = group
    parts.each do |part|
      current_group = current_group.children.find { |c| c.display_name == part || c.path == part } || current_group.new_group(part)
    end
    
    file_ref = current_group.new_file(filename)
    target.source_build_phase.add_file_reference(file_ref)
  end
end

project.save
