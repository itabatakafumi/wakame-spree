# require "passenger-recipes/passenger" # passenger用のcapistranoタスク

# ENV['SP_SERVER'] でデプロイ先のホストを指定します。
deploy_target = (ENV['SP_SERVER'] || 'localhost').strip
puts "Now deploying to #{deploy_target.inspect}"
db_server = ENV['DB_SERVER'] || "localhost"
mm_key_path = ENV['SP_KEY'] || "~/.ec2/goku-id_rsa"
unless File.exist?(File.expand_path(mm_key_path))
  raise "WARNING! You must set SP_KEY=/path/to/goku/private/key or copy it to ~/.ec2/goku-id_rsa"
end
 
set :application, "wakame-spree"
set :repository,  " http://github.com/itabatakafumi/wakame-spree.git"

set :scm, :git
# Or: `accurev`, `bzr`, `cvs`, `darcs`, `git`, `mercurial`, `perforce`, `subversion` or `none`
set :scm_verbose, true

set :user, "goku"
ssh_options[:user] = 'goku'
ssh_options[:forward_agent] = true
ssh_options[:keys] = mm_key_path
set :use_sudo, ARGV.first != "deploy:setup"

set :deploy_to, "/home/#{user}/capistrano/#{application}"
set :deploy_via, :remote_cache
set :copy_cache, true
set :keep_releases, 3

# passenger-recipesの設定
set :target_os, :ubuntu
set :apache_group, "www-data"
set :db, {}

role :web, deploy_target                   # Your HTTP server, Apache/etc
role :app, deploy_target                   # This may be the same as your `Web` server
role :db,  deploy_target, :primary => true # This is where Rails migrations will run

# If you are using Passenger mod_rails uncomment this:
# if you're still using the script/reapear helper you will need
# these http://github.com/rails/irs_process_scripts

desc "接続テスト用のタスク"
task :hello, :roles => [:app, :web, :db] do
  run "echo HelloWorld! $HOSTNAME"
end

namespace :app do
  desc "setup shared directories"
  task :setup_shared do
    run "mkdir -p #{shared_path}/config"
    config_spree = "#{shared_path}/config/spree_permissions.yml"
    put(IO.read("config/spree_permissions.yml"), config_spree, :via => :scp)
    config_db = "#{shared_path}/config/database.yml"
    put(IO.read("config/database.yml.example"), config_db, :via => :scp)
    todo_for('app', <<-"EOS")
      # TODO:
      # 1: If your server has never accessed to the repository.
      svn info #{repository}
      # 2: #{config_spree} has been copied. You MUST change settings.
      vi #{config_spree}
      # 3: #{config_db} has been copied. You MUST change password of it.
      vi #{config_db}
    EOS
  end

  desc "Make symlink for shared/config/database.yml" 
  task :symlinks do
    run "ln -nfs #{shared_path}/config/spree_permissions.yml #{release_path}/config/spree_permissions.yml"
    run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
  end
end
after "deploy:setup", "app:setup_shared"
after "deploy:update_code", "app:symlinks"


# http://henrik.nyh.se/2008/10/cap-gems-install-and-a-gem-dependency-gotcha
namespace :gems do
  desc "Install gems"
  task :install, :roles => :app do
    run "cd #{current_path} && #{sudo} rake RAILS_ENV=production gems:install"
  end

  desc "Install mysql lib for ruby"
  task :mysql, :roles => :app do
    run "#{sudo} apt-get install libmysql-ruby -y"
  end
end

after "deploy:setup", "gems:mysql"

# MYSQLのDBに関するタスク
namespace :mysql do
  %w(create drop migrate).each do |cmd|
    desc "#{cmd} database for production" 
    task cmd.to_sym do
      run "cd #{current_path} && RAILS_ENV=production rake db:#{cmd}"
    end
  end
  desc "database bootstrap for production"
  task :bootstrap do
    run "cd #{current_path} && rake RAILS_ENV=production db:bootstrap"
  end
end

namespace :apache do
  %w(start stop restart reload).each do |command|
    desc "apache #{command}"
    task(command){ run "#{sudo} /etc/init.d/apache2 #{command}" }
  end

  namespace :default_site do
    # zabbix-frontendの設定は以下のファイルに記述されています。
    #
    # /etc/apache2/conf.d/zabbix 
    # # Define /zabbix alias, this is the default
    # <IfModule mod_alias.c>
    #     Alias /zabbix /usr/share/zabbix
    # </IfModule>

    desc "enable default site"
    task(:enable) { run "#{sudo} a2ensite default" }

    desc "disable default site"
    task(:disable){ run "#{sudo} a2dissite default" }
  end

  namespace :wakame_spree do
    desc "setup wakame-spree site configuration"
    task :setup do
      path = "~/apache-passenger-wakame-spree"
      put(keep_indent(<<-EOS), path, :via => :scp)
      NameVirtualHost *:80 
        <VirtualHost *:80>
           ServerName #{deploy_target}
           DocumentRoot #{current_path}/public
           <Directory #{current_path}/public>
              AllowOverride all
              Options -MultiViews
           </Directory>
        </VirtualHost>
      EOS
      run "#{sudo} mv #{path} /etc/apache2/sites-available/wakame-spree"
    end

    desc "enable wakame-spree site"
    task(:enable) { run "#{sudo} a2ensite wakame-spree" }

    desc "disable wakame-spree site"
    task(:disable){ run "#{sudo} a2dissite wakame-spree" }
  end

end



# utility methods
def keep_indent(msg)
  lines = msg.split(/$/)
  indent = lines.first.scan(/^\s*/).first
  lines.map{|line| line.sub(/^#{indent}/, '')}.join
end

def todo_for(name, msg)
  msg = keep_indent(msg)
  put("= for #{name}\n#{msg}", "~/TODO-#{name}", :via => :scp)
 end

def show_todo
  run("echo \"#{'*' * 70}\"; cat ~/TODO-*; echo \"#{'*' * 70}\"")
end
