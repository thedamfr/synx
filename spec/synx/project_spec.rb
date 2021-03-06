require File.join(File.dirname(__FILE__), '..', 'spec_helper')

require 'fileutils'
require 'pathname'
require 'yaml'

class Hash
  # Return a hash that includes everything but the given keys. This is useful for
  # limiting a set of parameters to everything but a few known toggles:
  #
  #   @person.update_attributes(params[:person].except(:admin))
  #
  # If the receiver responds to +convert_key+, the method is called on each of the
  # arguments. This allows +except+ to play nice with hashes with indifferent access
  # for instance:
  #
  #   {:a => 1}.with_indifferent_access.except(:a)  # => {}
  #   {:a => 1}.with_indifferent_access.except("a") # => {}
  #
  def except(*keys)
    dup.except!(*keys)
  end

  # Replaces the hash without the given keys.
  def except!(*keys)
    keys.each { |key| delete(key) }
    self
  end
end

describe Synx::Project do

  DUMMY_SYNX_PATH = File.join(File.dirname(__FILE__), '..', 'dummy')
  DUMMY_SYNX_TEST_PATH = File.join(File.dirname(__FILE__), '..', 'test_dummy')
  DUMMY_SYNX_TEST_PROJECT_PATH = File.join(DUMMY_SYNX_TEST_PATH, 'dummy.xcodeproj')

  before(:all) do
    FileUtils.rm_rf(DUMMY_SYNX_TEST_PATH)
    FileUtils.cp_r(DUMMY_SYNX_PATH, DUMMY_SYNX_TEST_PATH)
    DUMMY_SYNX_TEST_PROJECT = Synx::Project.open(DUMMY_SYNX_TEST_PROJECT_PATH)
  end

  describe "#sync" do

    def verify_group_structure(group, expected_structure)
      expected_structure.each do |object_name, object_children|
        failure_message = "expected group `#{group.basename}` to have child `#{object_name}`"
        object = group.children.detect { |child| child.basename == object_name }
        expect(group).to_not be_nil, failure_message

        if object.instance_of?(Xcodeproj::Project::Object::PBXGroup)
          object_children ||= {}
          failure_message = "Expected #{object_name} to have #{object_children.count} children, found #{object.children.count}"
          expect(object_children.count).to eq(object.children.count), failure_message
          verify_group_structure(object, object_children) if object_children.count > 0
        end
      end
    end

    def verify_file_structure(dir_pathname, expected_structure)
      expected_structure.each do |entry_name, entry_entries|
        entry_pathname = dir_pathname + entry_name
        expect(File.exist?(entry_pathname) || Dir.exists?(entry_pathname)).to be(true), "Expected #{entry_pathname} to exist"

        if File.directory?(entry_pathname)
          entry_entries ||= {}
          # '.' and '..' show up in entries, so add 2
          failure_message = "Expected #{entry_pathname} to have #{entry_entries.count} children, found #{entry_pathname.entries.count - 2}"
          expect(entry_entries.count + 2).to eq(entry_pathname.entries.count), failure_message
          verify_file_structure(entry_pathname, entry_entries) if entry_entries.count > 0
        end
      end
    end

    def expected_file_structure
      YAML::load_file(File.join(File.dirname(__FILE__), "expected_file_structure.yml"))
    end

    def expected_group_structure
      YAML::load_file(File.join(File.dirname(__FILE__), "expected_group_structure.yml"))
    end

    describe "with no additional options" do

      before(:all) do
        DUMMY_SYNX_TEST_PROJECT.sync
      end

      it "should have the correct physical file structure" do
        verify_file_structure(Pathname(DUMMY_SYNX_TEST_PROJECT_PATH).parent, expected_file_structure)
      end

      it "should not have modified the Xcode group structure, except for fixing double file references" do
        verify_group_structure(DUMMY_SYNX_TEST_PROJECT.main_group, expected_group_structure)
      end

      it "should have updated the pch and info.plist build setting paths" do
        # dummy target
        DUMMY_SYNX_TEST_PROJECT.targets.first.each_build_settings do |bs|
          expect(bs["GCC_PREFIX_HEADER"]).to eq("dummy/Supporting Files/dummy-Prefix.pch")
          expect(bs["INFOPLIST_FILE"]).to be_nil
        end

        # dummyTests target
        DUMMY_SYNX_TEST_PROJECT.targets[1].each_build_settings do |bs|
          expect(bs["GCC_PREFIX_HEADER"]).to eq("dummyTests/Supporting Files/dummyTests-Prefix.pch")
          expect(bs["INFOPLIST_FILE"]).to eq("dummyTests/Supporting Files/dummyTests-Info.plist")
        end
      end
    end

    describe "with the prune option toggled" do

      before(:all) do
        DUMMY_SYNX_TEST_PROJECT.sync(:prune => true)
      end

      it "should remove unreferenced images and source files if the prune option is toggled" do
        expected_file_structure_with_removals = expected_file_structure
        expected_file_structure_with_removals["dummy"].except!("image-not-in-xcodeproj.png")
        expected_file_structure_with_removals["dummy"].except!("FileNotInXcodeProj.h")
        expected_file_structure_with_removals["dummy"]["AlreadySynced"]["FolderNotInXcodeProj"].except!("AnotherFileNotInXcodeProj.h")
        verify_file_structure(Pathname(DUMMY_SYNX_TEST_PROJECT_PATH).parent, expected_file_structure_with_removals)
      end

      it "should not have modified the Xcode group structure, except for fixing double file references" do
        verify_group_structure(DUMMY_SYNX_TEST_PROJECT.main_group, expected_group_structure)
      end
    end

    describe "with the no_default_exclusions option toggled" do

      before(:all) do
        DUMMY_SYNX_TEST_PROJECT.sync(:no_default_exclusions => true)
      end

      it "should have an empty array for default exclusions" do
        expect(DUMMY_SYNX_TEST_PROJECT.group_exclusions.count).to eq(0)
      end
    end

    describe "with group_exclusions provided as options" do

      before(:all) do
        DUMMY_SYNX_TEST_PROJECT.sync(:group_exclusions => %W(/dummy /dummy/SuchGroup/VeryChildGroup))
      end

      it "should add the group exclusions to the array" do
        expect(DUMMY_SYNX_TEST_PROJECT.group_exclusions.sort).to eq(%W(/Libraries /Products /Frameworks /dummy /dummy/SuchGroup/VeryChildGroup).sort)
      end
    end

  end

  describe "group_exclusions=" do

    it "should raise an IndexError if any of the groups do not exist" do
      expect { DUMMY_SYNX_TEST_PROJECT.group_exclusions = %W(/dummy /dummy/DoesntExist) }.to raise_error(IndexError)
    end

    it "should be fine if the groups all exist" do
      group_exclusions = %W(/dummy /dummy/GroupThatDoubleReferencesFile /dummy/SuchGroup/VeryChildGroup)
      DUMMY_SYNX_TEST_PROJECT.group_exclusions = group_exclusions

      expect(DUMMY_SYNX_TEST_PROJECT.group_exclusions).to eq(group_exclusions)
    end
  end

  describe "#root_pathname" do

    it "should return the pathname to the directory that the .pbxproj file is inside" do
      expected = Pathname(File.join(File.dirname(__FILE__), '..', 'test_dummy'))
      DUMMY_SYNX_TEST_PROJECT.send(:root_pathname).realpath.should eq(expected.realpath)
    end
  end

  describe "#work_root_pathname" do

    before(:each) { DUMMY_SYNX_TEST_PROJECT.instance_variable_set("@work_root_pathname", nil) }

    it "should return the pathname to the directory synxchronize will do its work in" do
      expected = Pathname(Synx::Project.const_get(:SYNXRONIZE_DIR)) + "test_dummy"
      DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname).realpath.should eq(expected.realpath)
    end

    it "should start fresh by removing any existing directory at work_root_pathname" do
      Pathname.any_instance.stub(:exist?).and_return(true)
      expect(FileUtils).to receive(:rm_rf)

      DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname)
    end

    it "should create a directory at work_root_pathname" do
      expect_any_instance_of(Pathname).to receive(:mkpath)
      DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname)
    end

    it "should be an idempotent operation but return the same value through memoization" do
      pathname = DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname)
      expect(FileUtils).to_not receive(:rm_rf)
      expect_any_instance_of(Pathname).to_not receive(:exist?)
      expect_any_instance_of(Pathname).to_not receive(:mkpath)
      expect(DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname)).to be(pathname)
    end
  end

  describe "#pathname_to_work_pathname" do

    it "should return the path in work_root_pathname that is relatively equivalent to root_pathname" do
      pathname = DUMMY_SYNX_TEST_PROJECT.send(:root_pathname) + "some" + "path" + "to" + "thing"

      value = DUMMY_SYNX_TEST_PROJECT.send(:pathname_to_work_pathname, pathname)
      expected = DUMMY_SYNX_TEST_PROJECT.send(:work_root_pathname) + "some" + "path" + "to" + "thing"

      expect(value).to eq(expected)
    end
  end
end