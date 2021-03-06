#  Copyright (C) 2017 IntechnologyWIFI / Michael Shaw
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'json'
require 'puppet_x/intechwifi/constants'
require 'puppet_x/intechwifi/logical'
require 'puppet_x/intechwifi/awscmds'
require 'puppet_x/intechwifi/exceptions'

#
#  The awscli provider for VPC's
#

#
#  This provider obtains resources on the fly, rather than caches the entire list of VPC's.  This provides significant performance improvements
#  when the region is part of the manifest declaration, and only a few VPC's are declared.
#

Puppet::Type.type(:vpc).provide(:awscli) do
  desc "Using the aws command line python application to implement changes"
  commands :awscli => "aws"

  def create
    vpc = JSON.parse(awscli('ec2', 'create-vpc', '--region', resource[:region], '--cidr-block', resource[:cidr]))
    @property_hash[:vpcid] = vpc["Vpc"]["VpcId"]
    @property_hash[:region] = resource[:region]
    @property_hash[:cidr] = resource[:cidr]

    awscli('ec2', 'create-tags', '--region', resource[:region], '--resources', @property_hash[:vpcid], '--tags', "Key=Name,Value=#{resource[:name]}")
    if resource[:dns_hostnames] then @property_flush[:dns_hostnames] = resource[:dns_hostnames] end
    if resource[:dns_resolution] then @property_flush[:dns_resolution] = resource[:dns_resolution] end

    route_id = JSON.parse(awscli('ec2', 'describe-route-tables', '--region', resource[:region], '--filter', "Name=vpc-id,Values=#{@property_hash[:vpcid]}"))["RouteTables"][0]["RouteTableId"]
    info("vpc #{resource[:name]} has a default route table #{route_id}")
    awscli('ec2', 'create-tags', '--region', resource[:region], '--resources', route_id, '--tags', "Key=Name,Value=#{resource[:name]}")

    sg_id = JSON.parse(awscli('ec2', 'describe-security-groups', '--region', resource[:region], '--filter', "Name=vpc-id,Values=#{@property_hash[:vpcid]}", "Name=group-name,Values=default"))["SecurityGroups"][0]["GroupId"]
    info("vpc #{resource[:name]} has a default security group #{sg_id}")
    awscli('ec2', 'create-tags', '--region', resource[:region], '--resources', sg_id, '--tags', "Key=Name,Value=#{resource[:name]}")

    @property_hash[:tags] = resource[:tags]
    PuppetX::IntechWIFI::Tags_Property.update_tags(@property_hash[:region], @property_hash[:vpcid], {}, @property_hash[:tags]){| *arg | awscli(*arg)}

    @property_hash[:ensure] = :present

  end

  def destroy
    route_id = JSON.parse(awscli('ec2', 'describe-route-tables', '--region', resource[:region], '--filter', "Name=vpc-id,Values=#{@property_hash[:vpcid]}"))["RouteTables"][0]["RouteTableId"]
    info("vpc #{resource[:name]} has a default route table #{route_id}")
    awscli('ec2', 'delete-tags', '--region', resource[:region], '--resources', route_id)

    response = awscli('ec2', 'delete-vpc', '--region', @property_hash[:region], '--vpc-id', @property_hash[:vpcid])
    debug("Clearing vpc-id cache for #{name}\n")
    PuppetX::IntechWIFI::AwsCmds.clear_vpc_tag_cache @property_hash[:name]
    @property_hash.clear
  end

  def exists?
    result = false

    #
    #  If the puppet manifest is delcaring the existance of a VPC then we know its region.
    #
    regions = [ resource[:region] ] if resource[:region]

    #
    #  If we don't know the region, then we have to search each region in turn.
    #
    regions = PuppetX::IntechWIFI::Constants.Regions if !resource[:region]

    debug("searching regions=#{regions} for vpc=#{resource[:name]}\n")

    search_result = PuppetX::IntechWIFI::AwsCmds.find_vpc_tag(regions, resource[:name]) do | *arg |
      awscli(*arg)
    end

    @property_hash[:ensure] = :present
    @property_hash[:vpcid] = search_result[:tag]["ResourceId"]
    @property_hash[:region] = search_result[:region]
    @property_hash[:name] = resource[:name]

    JSON.parse(awscli('ec2', 'describe-vpcs', '--region', @property_hash[:region], '--vpc-id', @property_hash[:vpcid]))["Vpcs"].map{|v| extract_values(@property_hash[:region], v) }

    true

  rescue PuppetX::IntechWIFI::Exceptions::NotFoundError => e
    debug(e)
    false

  rescue PuppetX::IntechWIFI::Exceptions::MultipleMatchesError => e
    fail(e)
    false
  end

  def extract_values(region, vpc)
    @property_hash[:tags] = PuppetX::IntechWIFI::Tags_Property.parse_tags(vpc["Tags"])

    @property_hash[:region] = region
    @property_hash[:cidr] = vpc["CidrBlock"]
    @property_hash[:dns_resolution] = get_dns_resolution(region, @property_hash[:vpcid])
    @property_hash[:dns_hostnames] = get_dns_hostnames(region, @property_hash[:vpcid])
    @property_hash[:state] = vpc["State"]

  end

  def get_dns_resolution(region, vpcid)
    PuppetX::IntechWIFI::Logical.logical(JSON.parse(awscli("ec2", "describe-vpc-attribute", "--vpc-id", "#{vpcid}", "--region", "#{region}", "--attribute", "enableDnsSupport"))["EnableDnsSupport"]["Value"])
  end

  def set_dns_resolution(region, vpcid, value)
    awscli("ec2", "modify-vpc-attribute", "--vpc-id", "#{vpcid}", "--region", "#{region}", "--enable-dns-support", "{\"Value\":#{PuppetX::IntechWIFI::Logical.string_true_or_false(value)}}")
  end


  def get_dns_hostnames(region, vpcid)
    PuppetX::IntechWIFI::Logical.logical(JSON.parse(awscli("ec2", "describe-vpc-attribute", "--vpc-id", "#{vpcid}", "--region", "#{region}", "--attribute", "enableDnsHostnames"))["EnableDnsHostnames"]["Value"])
  end

  def set_dns_hostnames(region, vpcid, value)
    awscli("ec2", "modify-vpc-attribute", "--vpc-id", "#{vpcid}", "--region", "#{region}", "--enable-dns-hostnames", "{\"Value\":#{PuppetX::IntechWIFI::Logical.string_true_or_false(value)}}")
  end

  def flush
    if @property_flush
      if @property_flush[:dns_hostnames] then set_dns_hostnames(@property_hash[:region], @property_hash[:vpcid], @property_flush[:dns_hostnames]) end
      if @property_flush[:dns_resolution] then set_dns_resolution(@property_hash[:region], @property_hash[:vpcid], @property_flush[:dns_resolution]) end
      PuppetX::IntechWIFI::Tags_Property.update_tags(@property_hash[:region], @property_hash[:vpcid], @property_hash[:tags], @property_flush[:tags]){| *arg | awscli(*arg)} if !@property_flush[:tags].nil?
    end
  end

  ###############################
  #
  #  Property Access
  #
  ###############################

  def initialize(value={})
    super(value)
    @property_flush = {}
  end

  mk_resource_methods

  def dns_hostnames=(value)
    @property_flush[:dns_hostnames] = value
  end

  def dns_resolution=(value)
    @property_flush[:dns_resolution] = value
  end

  def tags=(value)
    @property_flush[:tags] = value
  end


  def cidr=(value)
    fail("it is not possible to change the CIDR of an active VPC. you will need to delete it and then recreate it again.")
  end

  def region=(value)
    fail("it is not possible to change the region of an active VPC. you will need to delete it and then recreate it again in the new region")
  end

  def vpcid=(value)
    fail("The VPC ID is set by Amazon and cannot be changed.")
  end

end
