#!/usr/bin/env ruby

require 'rex/post/meterpreter/packet_response_waiter'
require 'rex/post/meterpreter/extensions/msfmap/tlv'
require 'rex/post/meterpreter/extensions/msfmap/constants'

module Rex
module Post
module Meterpreter
module Extensions
module MSFMap

###
#
# This meterpreter extension implements an in-memory portscanner with
# NMap like functionality.
#
###
class MSFMap < Extension

	attr_accessor :thread_holder_ptr, :number_of_threads

	def initialize(client)
		super(client, 'msfmap')
		client.register_extension_aliases(
			[
				{ 
					'name' => 'msfmap',
					'ext'	=> self
				},
			])
		@thread_holder_ptr = 0
		@number_of_threads = 0
	end
	
	def msfmap_init(opts = {})
		return if @thread_holder_ptr != 0
		# init shit here
		if opts.include?('ports')
			ports = opts['ports']
		elsif opts.include?('ports-top')
			ports = NMAP_TOP_1000_TCP_PORTS[0, opts['ports-top']]
		else
			ports = NMAP_TOP_1000_TCP_PORTS[0, 100]
		end
		if opts.include?('ping')
			ping = opts['ping']
		else
			ping = true
		end
		scan_type = opts['scan_type'] || 'tcp_connect'
		case scan_type
			when 'tcp_connect'
				scan_type = MSFMAP_OPTS_SCAN_TYPE_TCP_CONNECT
			when 'ping'
				scan_type = MSFMAP_OPTS_SCAN_TYPE_PING
		end
		
		timing_profile = opts['timing'] || 3	# get the timing profile 0-5 then translate it to the proper bit mask
		case timing_profile
			when 0	# DO NOT CHANGE THE NUMBER OF THREADS
				timing_profile = MSFMAP_OPTS_TIMING_0
				self.number_of_threads = 4
			when 1
				timing_profile = MSFMAP_OPTS_TIMING_1
				self.number_of_threads = 8
			when 2
				timing_profile = MSFMAP_OPTS_TIMING_2
				self.number_of_threads = 16
			when 3
				timing_profile = MSFMAP_OPTS_TIMING_3
				self.number_of_threads = 32
			when 4
				timing_profile = MSFMAP_OPTS_TIMING_4
				self.number_of_threads = 64
			when 5
				timing_profile = MSFMAP_OPTS_TIMING_5
				self.number_of_threads = 128
		end
		
		request = Packet.create_request('msfmap_init')
		portspacked = pack_ports(ports)
		request.add_tlv(TLV_TYPE_MSFMAP_PORTS_SPECIFICATION, portspacked)
		
		# configure option flags
		options = 0
		if ping
			options = (options | MSFMAP_OPTS_PING)
		end
		options = (options | timing_profile)
		options = (options | scan_type)
		
		request.add_tlv(TLV_TYPE_MSFMAP_SCAN_OPTIONS, options)
		
		response = client.send_request(request)
		thread_holder = response.get_tlv_value(TLV_TYPE_MSFMAP_THREAD_HOLDER_LOCATION)
		error_flags = response.get_tlv_value(TLV_TYPE_MSFMAP_RETURN_FLAGS)
		
		if (error_flags & MSFMAP_RET_ERROR_FLAGS) == 0
			@thread_holder_ptr = thread_holder
			return true
		else
			return false
		end
	end

	def msfmap_core(rex_ip_range)
		return if @thread_holder_ptr == 0
		
		# shits init'ed now run shit
		# build the first list of IPs to go
		ipaddrs = []
		self.number_of_threads.times do |i|
			next_ip = rex_ip_range.next_ip
			if next_ip == nil
				break
			end
			ipaddrs.push(inet_aton(next_ip))
		end
		ipaddrs = pack_ips(ipaddrs)
		
		ips_in_remote_queue = ((ipaddrs.length / 4) - 1)	# minus one for the null trailer
		while ips_in_remote_queue > 0
			request = Packet.create_request('msfmap_core')
			request.add_tlv(TLV_TYPE_MSFMAP_THREAD_HOLDER_LOCATION, @thread_holder_ptr)
			request.add_tlv(TLV_TYPE_MSFMAP_IPADDRESSES, ipaddrs)

			response = client.send_request(request)
			
			ips_in_remote_queue -= 1
			next_ip = rex_ip_range.next_ip
			if next_ip == nil
				ipaddrs = "\x00\x00\x00\x00"
			else
				ipaddrs = pack_ips( [ inet_aton(next_ip) ] )
				ips_in_remote_queue += 1
			end

			return_flags = response.get_tlv_value(TLV_TYPE_MSFMAP_RETURN_FLAGS)
			if ((return_flags & MSFMAP_RET_HOST_UP) == 0) or ((return_flags & MSFMAP_RET_ERROR_FLAGS) != 0)
				if (return_flags & MSFMAP_RET_ERROR_FLAGS) != 0
					puts ""
					puts "An Error Occured In The Remote Scan Thread"
					puts "\tComplete Flags: 0x#{return_flags.to_s(16)}"
					puts "\tError Flags:    0x#{(return_flags & MSFMAP_RET_ERROR_FLAGS).to_s(16)}"
					puts ""
					return
				end
				next	# host isn't up
			end
			host = response.get_tlv_value(TLV_TYPE_MSFMAP_IPADDRESSES)
			host = unpack_ips(host)
			host = inet_ntoa(host[0])
			open_ports = response.get_tlv_value(TLV_TYPE_MSFMAP_PORTS_OPEN)
			open_ports = unpack_ports(open_ports)
			host_result =	{	'host' => host,
								'open_ports' => open_ports,
							}
			yield [ host_result ]
		end
	end
	
	def msfmap_cleanup()
		return if @thread_holder_ptr == 0

		request = Packet.create_request('msfmap_cleanup')
		request.add_tlv(TLV_TYPE_MSFMAP_THREAD_HOLDER_LOCATION, @thread_holder_ptr)
		response = client.send_request(request)
		@thread_holder_ptr = 0
		return
	end
	
	def pack_ips(ips)
		ips.push(0)
		ipspacked = ips.pack("N" * ips.length)
		ips.pop()
		return ipspacked
	end
	
	def unpack_ips(ips)
		return ips.unpack("N" * (ips.length / 4))
	end
	
	def pack_ports(ports)
		# DONT GET RID OF THIS LINE
		ports.push(0)	# Must be null terminated for the C side of the code
		portspacked = ports.pack("S" * ports.length)
		ports.pop()		# Remove the trailing 0 so the original array is un altered
		return portspacked
	end
	
	def unpack_ports(ports)
		return ports.unpack("S" * (ports.length / 2))
	end
	
	def inet_aton(ip)
		nums = ip.split('.').collect{ |i| i.to_i }
		return (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | (nums[3])
	end

	def inet_ntoa(int)
		ipstr = []
		ipstr.push(((int & 0xff000000) >> 24).to_s)
		ipstr.push(((int & 0xff0000) >> 16).to_s)
		ipstr.push(((int & 0xff00) >> 8).to_s)
		ipstr.push((int & 0xff).to_s)
		return ipstr.join('.')
	end
end

end; end; end; end; end
