require 'net/ssh'
require 'socket'

module Jetpants
  
  # Encapsulates a UNIX server that we can SSH to as root. Maintains a pool of SSH
  # connections to the host as needed.
  class Host
    include CallbackHandler
    
    @@all_hosts = {}
    @@all_hosts_mutex = Mutex.new
    
    # IP address of the Host, as a string.
    attr_reader :ip
    
    # We override Host.new so that attempting to create a duplicate Host object
    # (that is, one with the same IP as an existing Host object) returns the
    # original object.
    def self.new(ip)
      @@all_hosts_mutex.synchronize do
        @@all_hosts[ip] = nil unless @@all_hosts[ip].is_a? self
        @@all_hosts[ip] ||= super
      end
    end
    
    def initialize(ip)
      @ip = ip
      @connection_pool = [] # array of idle Net::SSH::Connection::Session objects
      @lock = Mutex.new
      @available = nil
    end
    
    # Returns a Host object for the machine Jetpants is running on.
    def self.local(interface='bond0')
      # This technique is adapted from Sergio Rubio Gracia's, described at
      # http://blog.frameos.org/2006/12/09/getting-network-interface-addresses-using-ioctl-pure-ruby-2/
      sock = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM,0)
      buf = [interface, ""].pack('a16h16')
      sock.ioctl(0x8915, buf) # SIOCGIFADDR
      sock.close
      ip_string = buf[20...24].unpack('C*').join '.'
      self.new(ip_string)
    end
    
    # Returns a Net::SSH::Connection::Session for the host. Verifies that the
    # connection is working before returning it.
    def get_ssh_connection
      conn = nil
      attempts = 0
      5.times do |attempt|
        @lock.synchronize do
          if @connection_pool.count > 0
            conn = @connection_pool.shift
          end
        end
        unless conn
          params = {
            :paranoid => false,
            :user_known_hosts_file => '/dev/null',
            :timeout => 5,
          }
          params[:keys] = Jetpants.ssh_keys if Jetpants.ssh_keys
          begin
            @lock.synchronize do 
              conn = Net::SSH.start(@ip, 'root', params)
            end
          rescue => ex
            output "Unable to SSH on attempt #{attempt + 1}: #{ex.to_s}"
            conn = nil
            next
          end
        end
        
        # Confirm that the connection works
        if conn
          begin
            result = conn.exec!('echo ping').strip
            raise "Unexpected result" unless result == 'ping'
            @available = true
            return conn
          rescue
            output "Discarding nonfunctional SSH connection"
            conn = nil
          end
        end
      end
      @available = false
      raise "Unable to obtain working SSH connection to #{self} after 5 attempts"
    end
    
    # Adds a Net::SSH::Connection::Session to a pool of idle persistent connections.
    def save_ssh_connection(conn)
      conn.exec! 'cd ~'
      @lock.synchronize do
        @connection_pool << conn
      end
    rescue
      output "Discarding nonfunctional SSH connection"
    end
    
    # Execute the given UNIX command string (or array of strings) as root via SSH.
    # By default, if something is wrong with the SSH connection, the command 
    # will be attempted up to 3 times before an exception is thrown. Be sure
    # to set this to 1 or false for commands that are not idempotent.
    # Returns the result of the command executed. If cmd was an array of strings,
    # returns the result of the LAST command executed.
    def ssh_cmd(cmd, attempts=3)
      attempts ||= 1
      conn = get_ssh_connection
      cmd = [cmd] unless cmd.is_a? Array
      result = nil
      cmd.each do |c|
        failures = 0
        begin
          result = conn.exec! c
        rescue
          failures += 1
          raise if failures >= attempts
          output "Command \"#{c}\" failed, re-trying after delay"
          sleep(failures)
          retry
        end
      end
      save_ssh_connection conn
      return result
    end
    
    # Shortcut for use when a command is not idempotent and therefore
    # isn't safe to retry if something goes wonky with the SSH connection.
    def ssh_cmd!(cmd)
      ssh_cmd cmd, false
    end
    
    # Confirm that something is listening on the given port. The timeout param
    # indicates how long to wait (in seconds) for a process to be listening.
    def confirm_listening_on_port(port, timeout=10)
      checker_th = Thread.new { ssh_cmd "while [[ `netstat -ln | grep #{port} | wc -l` -lt 1 ]] ; do sleep 1; done" }
      raise "Nothing is listening on #{@ip}:#{port} after #{timeout} seconds" unless checker_th.join(timeout)
      true
    end
    
    # Returns true if the host is accessible via SSH, false otherwise
    def available?
      # If we haven't tried an ssh command yet, @available will be nil. Running
      # a first no-op command will populate it to true or false.
      if @available.nil?
        ssh_cmd 'echo ping' rescue nil
      end
      @available
    end
    
    ###### ini file manipulation ###############################################
    
    # Comments-out lines of an ini file beginning with any of the supplied prefixes
    def comment_out_ini(file, *prefixes)
      toggle_ini(file, prefixes, false)
    end
    
    # Un-comments-out lines of an ini file beginning with any of the supplied prefixes
    # The prefixes should NOT include the # comment-out character -- ie, pass them
    # the same as you would to DB#comment_out_ini
    def uncomment_out_ini(file, *prefixes)
      toggle_ini(file, prefixes, true)
    end
    
    # Comments-out (if enable is true) or un-comments-out (if enable is false) lines of an ini file.
    def toggle_ini(file, prefixes, enable)
      prefixes.flatten!
      commands = []
      prefixes.each do |setting|
        if enable
          search = '^#(\s*%s\s*(?:=.*)?)$' % setting
          replace = '\1'
        else
          search = '^(\s*%s\s*(?:=.*)?)$' % setting
          replace = '#\1'
        end
        commands << "ruby -i -pe 'sub(%r[#{search}], %q[#{replace}])' #{file}"
      end
      cmd_line = commands.join '; '
      ssh_cmd cmd_line
    end
    
    
    ###### Directory Copying / Listing / Comparison methods ####################
    
    # Quickly and efficiently recursively copies a directory to one or more target hosts.
    # Requires that pigz is installed on source (self) and all targets.
    # base_dir::  is base directory to copy from the source (self). Also the default destination base
    #             directory on the targets, if not supplied via next param.
    # targets::   is one of the following:
    #             * Host object, or any object that delegates method_missing to a Host (such as DB)
    #             * array of Host objects (or delegates)
    #             * hash mapping Host objects (or delegates) to destination base directory overrides (as string)
    # options::   is a hash that can contain --
    #             * :files            =>  only copy these filenames instead of entire base_dir. String, or Array of Strings.
    #             * :port             =>  port number to use for netcat. defaults to 7000 if omitted.
    #             * :overwrite        =>  if true, don't raise an exception if the base_dir is non-empty or :files exist. default false.
    def fast_copy_chain(base_dir, targets, options={})
      # Normalize the filesnames param so it is an array
      filenames = options[:files] || ['.']
      filenames = [filenames] unless filenames.respond_to?(:each)
      
      # Normalize the targets param, so that targets is an array of Hosts and
      # destinations is a hash of hosts => dirs
      destinations = {}
      targets = [targets] unless targets.respond_to?(:each)
      base_dir += '/' unless base_dir[-1] == '/'
      if targets.is_a? Hash
        destinations = targets
        destinations.each {|t, d| destinations[t] += '/' unless d[-1] == '/'}
        targets = targets.keys
      else
        destinations = targets.inject({}) {|memo, target| memo[target] = base_dir; memo}
      end
      raise "No target hosts supplied" if targets.count < 1
      
      file_list = filenames.join ' '
      port = (options[:port] || 7000).to_i
      
      # On each destination host, do any initial setup (and optional validation/erasing),
      # and then listen for new files.  If there are multiple destination hosts, all of them
      # except the last will use tee to "chain" the copy along to the next machine.
      workers = []
      targets.reverse.each_with_index do |t, i|
        dir = destinations[t]
        raise "Directory #{t}:#{dir} looks suspicious" if dir.include?('..') || dir.include?('./') || dir == '/' || dir == ''
        
        t.confirm_installed 'pigz'
        t.ssh_cmd "mkdir -p #{dir}"
        
        # Check if contents already exist / non-empty.
        # Note: doesn't do recursive scan of subdirectories
        unless options[:overwrite]
          all_paths = filenames.map {|f| dir + f}.join ' '
          dirlist = t.dir_list(all_paths)
          dirlist.each {|name, size| raise "File #{name} exists on destination and has nonzero size!" if size.to_i > 0}
        end
        
        if i == 0
          workers << Thread.new { t.ssh_cmd "cd #{dir} && nc -l #{port} | pigz -d | tar xvf -" }
          t.confirm_listening_on_port port
          t.output "Listening with netcat."
        else
          tt = targets.reverse[i-1]
          fifo = "fifo#{port}"
          workers << Thread.new { t.ssh_cmd "cd #{dir} && mkfifo #{fifo} && nc #{tt.ip} #{port} <#{fifo} && rm #{fifo}" }
          checker_th = Thread.new { t.ssh_cmd "while [ ! -p #{dir}/#{fifo} ] ; do sleep 1; done" }
          raise "FIFO not found on #{t} after 10 tries" unless checker_th.join(10)
          workers << Thread.new { t.ssh_cmd "cd #{dir} && nc -l #{port} | tee #{fifo} | pigz -d | tar xvf -" }
          t.confirm_listening_on_port port
          t.output "Listening with netcat, and chaining to #{tt}."
        end
      end
      
      # Start the copy chain.
      confirm_installed 'pigz'
      output "Sending files over to #{targets[0]}: #{file_list}"
      ssh_cmd "cd #{base_dir} && tar vc #{file_list} | pigz | nc #{targets[0].ip} #{port}"
      workers.each {|th| th.join}
      output "File copy complete."
      
      # Verify
      output "Verifying file sizes and types on all destinations."
      compare_dir base_dir, destinations, options
      output "Verification successful."
    end
    
    # Given the name of a directory or single file, returns a hash of filename => size of each file present.
    # Subdirectories will be returned with a size of '/', so you can process these differently as needed.
    # WARNING: This is brittle. It parses output of "ls". If anyone has a gem to do better remote file
    # management via ssh, then please by all means send us a pull request!
    def dir_list(dir)
      ls_out = ssh_cmd "ls --color=never -1AgGF #{dir}"  # disable color, 1 file per line, all but . and .., hide owner+group, include type suffix
      result = {}
      ls_out.split("\n").each do |line|
        next unless matches = line.match(/^[\w-]+\s+\d+\s+(?<size>\d+).*(?:\d\d:\d\d|\d{4})\s+(?<name>.*)$/)
        file_name = matches[:name]
        file_name = file_name[0...-1] if file_name =~ %r![*/=>@|]$!
        result[file_name.split('/')[-1]] = (matches[:name][-1] == '/' ? '/' : matches[:size].to_i)
      end
      result
    end
    
    # Compares file existence and size between hosts. Param format identical to
    # the first three params of Host#fast_copy_chain, except only supported option
    # is :files.
    # Raises an exception if the files don't exactly match, otherwise returns true.
    def compare_dir(base_dir, targets, options={})
      # Normalize the filesnames param so it is an array
      filenames = options[:files] || ['.']
      filenames = [filenames] unless filenames.respond_to?(:each)
      
      # Normalize the targets param, so that targets is an array of Hosts and
      # destinations is a hash of hosts => dirs
      destinations = {}
      targets = [targets] unless targets.respond_to?(:each)
      base_dir += '/' unless base_dir[-1] == '/'
      if targets.is_a? Hash
        destinations = targets
        destinations.each {|t, d| destinations[t] += '/' unless d[-1] == '/'}
        targets = targets.keys
      else
        destinations = targets.inject({}) {|memo, target| memo[target] = base_dir; memo}
      end
      raise "No target hosts supplied" if targets.count < 1
      
      queue = filenames.map {|f| ['', f]}  # array of [subdir, filename] pairs
      while (tuple = queue.shift)
        subdir, filename = tuple
        source_dirlist = dir_list(base_dir + subdir + filename)
        destinations.each do |target, path|
          target_dirlist = target.dir_list(path + subdir + filename)
          source_dirlist.each do |name, size|
            target_size = target_dirlist[name] || 'MISSING'
            raise "Directory listing mismatch when comparing #{self}:#{base_dir}#{subdir}#{filename}/#{name} to #{target}:#{path}#{subdir}#{filename}/#{name}  (size: #{size} vs #{target_size})" unless size == target_size
          end
        end
        queue.concat(source_dirlist.map {|name, size| size == '/' ? [subdir + '/' + name, '/'] : nil}.compact)
      end
    end
    
    # Recursively computes size of files in dir
    def dir_size(dir)
      total_size = 0
      dir_list(dir).each do |name, size|
        total_size += (size == '/' ? dir_size(dir + '/' + name) : size.to_i)
      end
      total_size
    end
    
    
    ###### Misc methods ########################################################
    
    # Performs the given operation ('start', 'stop', 'restart') on the specified
    # service. Default implementation assumes RedHat/CentOS style /sbin/service.
    # If you're using a distibution or OS that does not support /sbin/service,
    # override this method with a plugin.
    def service(operation, name)
      ssh_cmd "/sbin/service #{name} #{operation.to_s}"
    end
    
    # Changes the I/O scheduler to name (such as 'deadline', 'noop', 'cfq')
    # for the specified device.
    def set_io_scheduler(name, device='sda')
      output "Setting I/O scheduler for #{device} to #{name}."
      ssh_cmd "echo '#{name}' >/sys/block/#{device}/queue/scheduler"
    end
    
    # Confirms that the specified binary is installed and on the shell path.
    def confirm_installed(program_name)
      out = ssh_cmd "which #{program_name}"
      raise "#{program_name} not installed, or missing from path" if out =~ /no #{program_name} in /
      true
    end
    
    # Returns number of cores on machine. (reflects virtual cores if hyperthreading
    # enabled, so might be 2x real value in that case.)
    # Not currently used by anything in Jetpants base, but might be useful for plugins
    # that want to tailor the concurrency level to the machine's capabilities.
    def cores
      return @cores if @cores
      count = ssh_cmd %q{cat /proc/cpuinfo|grep 'processor\s*:' | wc -l}
      @cores = (count ? count.to_i : 1)
    end
    
    # Returns the machine's hostname
    def hostname
      @hostname ||= ssh_cmd('hostname').chomp
    end
    
    # Displays the provided output, along with information about the current time,
    # and self (the IP of this Host)
    def output(str)
      str = str.to_s.strip
      str = nil if str && str.length == 0
      str ||= "Completed (no output)"
      output = Time.now.strftime("%H:%M:%S") + " [#{self}] "
      output << str
      print output + "\n"
      output
    end
    
    # Returns the host's IP address as a string.
    def to_s
      return @ip
    end
    
    # Returns self, since this object is already a Host.
    def to_host
      self
    end
    
  end
end
