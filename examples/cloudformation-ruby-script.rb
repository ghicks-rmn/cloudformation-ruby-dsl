#!/usr/bin/env ruby

# Copyright 2013-2014 Bazaarvoice, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'bundler/setup'
require 'cloudformation-ruby-dsl/cfntemplate'
require 'cloudformation-ruby-dsl/table'

# Note: this is only intended to demonstrate the cloudformation-ruby-dsl. It compiles
#   and validates correctly, but won't produce a viable CloudFormation stack.

template do

  parameter 'Label',
            :Description => 'The label to apply to the servers.',
            :Type => 'String',
            :MinLength => '2',
            :MaxLength => '25',
            :AllowedPattern => '[_a-zA-Z0-9]*',
            :ConstraintDescription => 'Maximum length of the Label parameter may not exceed 25 characters and may only contain letters, numbers and underscores.',
            # The :Immutable attribute is a Ruby CFN extension.  It affects the behavior of the '<template> cfn-update-stack ...'
            # operation in that a stack update may not change the values of parameters marked w/:Immutable => true.
            :Immutable => true

  parameter 'InstanceType',
            :Description => 'EC2 instance type',
            :Type => 'String',
            :Default => 'm2.xlarge',
            :AllowedValues => %w(t1.micro m1.small m1.medium m1.large m1.xlarge m2.xlarge m2.2xlarge m2.4xlarge c1.medium c1.xlarge),
            :ConstraintDescription => 'Must be a valid EC2 instance type.'

  parameter 'ImageId',
            :Description => 'EC2 Image ID',
            :Type => 'String',
            :Default => 'ami-255bbc4c',
            :AllowedPattern => 'ami-[a-f0-9]{8}',
            :ConstraintDescription => 'Must be ami-XXXXXXXX (where X is a hexadecimal digit)'

  parameter 'KeyPairName',
            :Description => 'Name of KeyPair to use.',
            :Type => 'String',
            :MinLength => '1',
            :MaxLength => '40',
            :Default => parameters['Label']

  parameter 'EmailAddress',
            :Type => 'String',
            :Description => 'Email address at which to send notification events.'

  mapping 'InlineExampleMap',
          :team1 => {
              :name => 'test1',
              :email => 'test1@example.com',
          },
          :team2 => {
              :name => 'test2',
              :email => 'test2@example.com',
          }

  # Generates mappings from external files with various formats.
  mapping 'JsonExampleMap', 'maps/map.json'

  mapping 'RubyExampleMap', 'maps/map.rb'

  mapping 'YamlExampleMap', 'maps/map.yaml'

  # Loads JSON mappings dynamically from example directory.
  Dir.entries('maps/more_maps').each_with_index do |path, index|
    next if path == "." or path == ".."
    mapping "ExampleMap#{index - 1}", "maps/more_maps/#{path}"
  end

  # Selects all rows in the table which match the name/value pairs of the predicate object and returns a
  # set of nested maps, where the key for the map at level n is the key at index n in the specified keys,
  # except for the last key in the specified keys which is used to determine the value of the leaf-level map.
  text = Table.load 'maps/table.txt'
  mapping 'TableExampleMap',
      text.get_map({ :column0 => 'foo' }, :column1, :column2, :column3)

  # Shows how to create a table useful for looking up subnets that correspond to a particular env/region for eg. vpc placement.
  vpc = Table.load 'maps/vpc.txt'
  mapping 'TableExampleMultimap',
          vpc.get_multimap({ :visibility => 'private', :zone => ['a', 'c'] }, :env, :region, :subnet)

  # The tag type is a Ruby CFN extension. These tags are excised from the template and used to generate a series of --tag arguments
  #   which are passed to cfn-cmd. They do not ultimately appear in the expanded CloudFormation template. The diff subcommand will
  #   compare tags with the running stack and identify any changes, but cfn-update-stack will do the diff and throw an error on any
  #   changes. The tags are propagated to all resources created by the stack, including the stack itself.
  #
  # Amazon has set the following restrictions on CloudFormation tags:
  #   => limit 10
  #   => immutable (you may not cfn-update-stack with new tags or different values for existing tags -- they will be rejected)
  #
  # Additionally, cfn-cmd throws an error if your tag value contains spaces. This limitation will be lifted when we move from cfn-cmd
  #   to the new unified CLI.
  tag :MyTag => 'MyValue'

  resource 'SecurityGroup', :Type => 'AWS::EC2::SecurityGroup', :Properties => {
      :GroupDescription => 'Lets any vpc traffic in.',
      :SecurityGroupIngress => {:IpProtocol => '-1', :FromPort => '0', :ToPort => '65535', :CidrIp => "10.0.0.0/8"}
  }

  resource "ASG", :Type => 'AWS::AutoScaling::AutoScalingGroup', :Properties => {
      :AvailabilityZones => 'us-east-1',
      :HealthCheckType => 'EC2',
      :LaunchConfigurationName => ref('LaunchConfig'),
      :MinSize => 1,
      :MaxSize => 5,
      :NotificationConfiguration => {
          :TopicARN => ref('EmailSNSTopic'),
          :NotificationTypes => %w(autoscaling:EC2_INSTANCE_LAUNCH autoscaling:EC2_INSTANCE_LAUNCH_ERROR autoscaling:EC2_INSTANCE_TERMINATE autoscaling:EC2_INSTANCE_TERMINATE_ERROR),
      },
      :Tags => [
          {
              :Key => 'Name',
              # Grabs a value in an external map file.
              :Value => find_in_map('TableExampleMap', 'corge', 'grault'),
              :PropagateAtLaunch => 'true',
          },
          {
              :Key => 'Label',
              :Value => parameters['Label'],
              :PropagateAtLaunch => 'true',
          }
      ],
  }

  resource 'EmailSNSTopic', :Type => 'AWS::SNS::Topic', :Properties => {
      :Subscription => [
          {
              :Endpoint => ref('EmailAddress'),
              :Protocol => 'email',
          },
      ],
  }

  resource 'WaitConditionHandle', :Type => 'AWS::CloudFormation::WaitConditionHandle', :Properties => {}

  resource 'WaitCondition', :Type => 'AWS::CloudFormation::WaitCondition', :DependsOn => 'ASG', :Properties => {
      :Handle => ref('WaitConditionHandle'),
      :Timeout => 1200,
      :Count => "1"
  }

  resource 'LaunchConfig', :Type => 'AWS::AutoScaling::LaunchConfiguration', :Properties => {
      :ImageId => parameters['ImageId'],
      :KeyName => ref('KeyPairName'),
      :IamInstanceProfile => ref('InstanceProfile'),
      :InstanceType => ref('InstanceType'),
      :InstanceMonitoring => 'false',
      :SecurityGroups => [ref('SecurityGroup')],
      :BlockDeviceMappings => [
          {:DeviceName => '/dev/sdb', :VirtualName => 'ephemeral0'},
          {:DeviceName => '/dev/sdc', :VirtualName => 'ephemeral1'},
          {:DeviceName => '/dev/sdd', :VirtualName => 'ephemeral2'},
          {:DeviceName => '/dev/sde', :VirtualName => 'ephemeral3'},
      ],
      # Loads an external userdata script.
      :UserData => base64(interpolate(file('userdata.sh'))),
  }

  resource 'InstanceProfile', :Type => 'AWS::IAM::InstanceProfile', :Properties => {
      :Path => '/',
      :Roles => [ ref('InstanceRole') ],
  }

  resource 'InstanceRole', :Type => 'AWS::IAM::Role', :Properties => {
      :AssumeRolePolicyDocument => {
          :Statement => [
              {
                  :Effect => 'Allow',
                  :Principal => { :Service => [ 'ec2.amazonaws.com' ] },
                  :Action => [ 'sts:AssumeRole' ],
              },
          ],
      },
      :Path => '/',
  }

  output 'EmailSNSTopicARN',
          :Value => ref('EmailSNSTopic'),
          :Description => 'ARN of SNS Topic used to send emails on events.'

  output 'MappingLookup',
          :Value => find_in_map('TableExampleMap', 'corge', 'grault'),
          :Description => 'An example map lookup.'

end.exec!
