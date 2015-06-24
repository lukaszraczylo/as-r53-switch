#!/usr/bin/env ruby
require 'trollop'
require 'aws-sdk'

MAINTENANCE_MODE_DOMAIN = 'e6211db0073064ade016ad4558767968' # md5 hash from 'maintenance-mode'

class R53Switch
  def initialize
    $opts = parse_options
    $domain_data = Hash.new
    $r53 = Aws::Route53::Client.new(:region => 'eu-west-1')
    manage
  end

  def manage
    $r53.list_hosted_zones.each do |hosted_zone|
      hosted_zone.hosted_zones.each do |hz|
        if hz.name =~ /^#{$opts.domain.to_s}/
          $domain_data['id'] = hz.id
          $domain_data['domain_name'] = hz.name
          d = $r53.list_resource_record_sets(:hosted_zone_id => $domain_data['id'], :start_record_name => "#{$opts.record.to_s}.#{$opts.domain.to_s}.", :max_items => 10)
          rec = d.resource_record_sets.detect {|record| record["name"] =~ /^#{$opts.record.to_s}.#{$opts.domain.to_s}\./ }
          if rec
            $domain_data['record_exists'] = true
            $domain_data['original_type'] = rec.type
            $domain_data['original_values'] = rec.resource_records
            $domain_data['original_name'] = "#{$opts.record.to_s}.#{$opts.domain.to_s}"
          else
            $domain_data['record_exists'] = false
          end
          w = $r53.list_resource_record_sets(:hosted_zone_id => $domain_data['id'], :start_record_name => "#{MAINTENANCE_MODE_DOMAIN}.#{$opts.domain.to_s}.", :max_items => 10)
          wec = w.resource_record_sets.detect {|record| record["name"] =~ /^#{MAINTENANCE_MODE_DOMAIN}.#{$opts.domain.to_s}\./ }
          if wec
            $domain_data['maintenance_exists'] = true
            $domain_data['maintenance_type'] = wec.type
            $domain_data['maintenance_values'] = wec.resource_records
            $domain_data['maintenance_name'] = "#{MAINTENANCE_MODE_DOMAIN}.#{$opts.domain.to_s}"
          else
            $domain_data['maintenance_exists'] = false
          end
        end
      end
    end
    # Our domain already exists - there's no need to create one.
    $domain_data['record_exists'] == true ? nil : create_record($opts.domain, $opts.record); self
    $domain_data['maintenance_exists'] == true ? nil : create_record($opts.domain, MAINTENANCE_MODE_DOMAIN); self
    # At this stage all the records should exist - we can try switching them over.
    if $domain_data['record_exists'] && $domain_data['maintenance_exists']
      toggle_domain_records
    end
  end

  def toggle_domain_records
    change_dns_options = [
      {
        :action => 'DELETE',
        :resource_record_set => {
          :name => "#{$domain_data['original_name']}.",
          :type => $domain_data['original_type'],
          :ttl => 60,
          :resource_records => $domain_data['original_values']
        }
      },
      {
        :action => 'DELETE',
        :resource_record_set => {
          :name => "#{$domain_data['maintenance_name']}.",
          :type => $domain_data['maintenance_type'],
          :ttl => 60,
          :resource_records => $domain_data['maintenance_values']
        }
      },
    ]
    res = $r53.change_resource_record_sets({
      :hosted_zone_id => $domain_data['id'],
      :change_batch => {:changes => change_dns_options}
    })
    change_dns_options = [{
        :action => 'CREATE',
        :resource_record_set => {
          :name => "#{$domain_data['original_name']}.",
          :type => $domain_data['maintenance_type'],
          :ttl => 60,
          :resource_records => $domain_data['maintenance_values']
        }
      },
      {
        :action => 'CREATE',
        :resource_record_set => {
          :name => "#{$domain_data['maintenance_name']}.",
          :type => $domain_data['original_type'],
          :ttl => 60,
          :resource_records => $domain_data['original_values']
        }
    } ]
    res = $r53.change_resource_record_sets({
      :hosted_zone_id => $domain_data['id'],
      :change_batch => {:changes => change_dns_options}
    })
    puts "DNS records toggled with TTL of 60s. Run again to restore."
  end

  def create_record(domain, record)
    puts "Non existent record - creating: #{record}.#{domain}"
    change_dns_options = [
        {
          :action => 'CREATE',
          :resource_record_set => {
              :name => "#{record}.#{domain}.",
              :type => 'CNAME',
              :ttl => '60',
              :resource_records => [ {:value => 'www.gov.uk.'} ]
          }
        }
      ]
      res = $r53.change_resource_record_sets({
          :hosted_zone_id => $domain_data['id'],
          :change_batch => {:changes => change_dns_options}
      })
      res[:change_info][:status] == 'PENDING' ? $domain_data['record_exists'] = true : nil
  end

  def parse_options
    opts = Trollop::options do
      opt :domain, "Domain to fiddle with", :type => :string, :required => true
      opt :record, "Subdomain record which we want to change", :type => :string, :required => true
      opt :temporary, "Holder subdomain, if not specified it defaults to maintenance-mode.$domain", :type => :string
    end
    return opts
  end
end

r = R53Switch.new