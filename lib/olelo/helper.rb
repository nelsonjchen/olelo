module Olelo
  module BlockHelper
    def blocks
      @blocks ||= Hash.with_indifferent_access('')
    end

    def define_block(name, content = nil, &block)
      if block || content
        blocks[name] = block ? capture_haml(&block) : content
      else
        blocks[name]
      end
    end

    def footer(content = nil, &block); define_block(:footer, content, &block); end
    def title(content = nil, &block);  define_block(:title,  content, &block); end
  end

  module FlashHelper
    include Util

    class Flash < Hash
      def error(msg); (self[:error] ||= []) << msg; end
      def warn(msg);  (self[:warn]  ||= []) << msg; end
      def info(msg);  (self[:info]  ||= []) << msg; end
    end

    def flash
      session[:flash] ||= Flash.new
    end

    def flash_messages
      if !flash.empty?
        li = flash.map {|level, list| list.map {|msg| %{<li class="flash #{level}">#{escape_html msg}</li>} } }.flatten
        flash.clear
        "<ul>#{li.join}</ul>"
      end
    end
  end

  module PageHelper
    include Util

    def pagination(path, last_page, page_nr, opts = {})
      if last_page > 0
        li = []
        if page_nr > 0
          li << %{<a href="#{escape_html absolute_path(path, opts.merge(:page => 0))}">&#171;</a>}
          li << %{<a href="#{escape_html absolute_path(path, opts.merge(:page => page_nr - 1))}">&#8249;</a>}
        end
        min = page_nr - 3
        max = page_nr + 3
        if min > 0
          min -= max - last_page if max > last_page
        else
          max -= min if min < 0
        end
        max = [max, last_page].min
        min = [min, 0].max
        li << '&#8230;' if min != 0
        (min..max).each do |i|
          if i == page_nr
            li << %{<a class="current" href="#">#{i + 1}</a>}
          else
            li << %{<a href="#{escape_html absolute_path(path, opts.merge(:page => i))}">#{i + 1}</a>}
          end
        end
        li << '&#8230;' if max != last_page
        if page_nr < last_page
          li << %{<a href="#{escape_html absolute_path(path, opts.merge(:page => page_nr + 1))}">&#8250;</a>}
          li << %{<a href="#{escape_html absolute_path(path, opts.merge(:page => last_page))}">&#187;</a>}
        end
        '<ul class="pagination">' + li.map {|x| "<li>#{x}</li>"}.join + '</ul>'
      end
    end

    def date(t)
      %{<span class="date epoch-#{t.to_i}">#{t.strftime('%d %h %Y %H:%M')}</span>}
    end

    def format_diff(diff)
      summary   = PatchSummary.new(:links => true)
      formatter = PatchFormatter.new(:links => true, :header => true)
      PatchParser.parse(diff.patch, summary, formatter)
      summary.html + formatter.html
    end

    def breadcrumbs(page)
      path = page.try(:path) || ''
      li = [%{<li class="first breadcrumb#{path.empty? ? ' last' : ''}">
              <a accesskey="z" class="root" href="#{escape_html page_path(page, :path => '/')}">#{escape_html :root.t}</a></li>}.unindent]
      path.split('/').inject('') do |parent,elem|
        current = parent/elem
        li << %{<li class="breadcrumb#{current == path ? ' last' : ''}">
                <a href="#{escape_html page_path(page, :path => '/' + current)}">#{escape_html elem}</a></li>}.unindent
        current
      end
      li.join('<li class="breadcrumb">/</li>')
    end

    def absolute_path(path, opts = {})
      path = '/' + Config.base_path/(path.try(:path) || path).to_s
      path += '?' + build_query(opts) if !opts.empty?
      path
    end

    def page_path(page, opts = {})
      version = opts.delete(:version) || (page && !page.current? && page.tree_version) || ''
      if path = opts.delete(:path)
        path = page.path/'..'/path if !path.begins_with? '/'
      else
        path = page.path
      end
      path = path/'version'/version if !version.blank?
      absolute_path(path, opts)
    end

    def action_path(path, action)
      absolute_path((path.try(:path) || path).to_s / action.to_s)
    end

    def edit_content(page)
      if params[:content]
        params[:content]
      elsif !page.content.valid_text_encoding?
        :error_binary.t(:page => page.title, :type => "#{page.mime.comment} (#{page.mime})")
      else
        params[:pos] ? page.content[params[:pos].to_i, params[:len].to_i].to_s : page.content
      end
    end
  end

  module HttpHelper
    include Util

    # Cache control for page
    def cache_control(opts)
      return if !Config.production?

      if opts[:no_cache]
        response.headers.delete('ETag')
        response.headers.delete('Last-Modified')
        response['Cache-Control'] = 'no-cache'
        return
      end

      last_modified = opts.delete(:last_modified)
      modified_since = env['HTTP_IF_MODIFIED_SINCE']
      last_modified = last_modified.try(:to_time) || last_modified
      last_modified = last_modified.try(:httpdate) || last_modified

      if @user && !@user.anonymous?
        # Always private mode if user is logged in
        opts[:private] = true

        # Special etag for authenticated user
        opts[:etag] = "#{@user.name}-#{opts[:etag]}" if opts[:etag]
      end

      # Spcial etag for ajax request
      opts[:etag] = "xhr-#{opts[:etag]}" if request.xhr?

      if opts[:etag]
        value = '"%s"' % opts.delete(:etag)
        response['ETag'] = value.to_s
        response['Last-Modified'] = last_modified if last_modified
        if etags = env['HTTP_IF_NONE_MATCH']
          etags = etags.split(/\s*,\s*/)
          # Etag is matching and modification date matches (HTTP Spec §14.26)
          halt :not_modified if (etags.include?(value) || etags.include?('*')) && (!last_modified || last_modified == modified_since)
        end
      elsif last_modified
        # If-Modified-Since is only processed if no etag supplied.
        # If the etag match failed the If-Modified-Since has to be ignored (HTTP Spec §14.26)
        response['Last-Modified'] = last_modified
        halt :not_modified if last_modified == modified_since
      end

      opts[:public] = !opts[:private]
      opts[:max_age] ||= 0
      opts[:must_revalidate] ||= true if !opts.include?(:must_revalidate)

      response['Cache-Control'] = opts.map do |k, v|
        if v == true
          k.to_s.tr('_', '-')
        elsif v
          v = 31536000 if v.to_s == 'static'
          "#{k.to_s.tr('_', '-')}=#{v}"
        end
      end.compact.join(', ')
    end
  end

  module ApplicationHelper
    include BlockHelper
    include FlashHelper
    include PageHelper
    include HttpHelper

    def tab(action)
      %{<li id="tabheader-#{action}"#{action?(action) ? ' class="selected"' : ''}><a href="#tab-#{action}">#{escape_html action.t}</a></li>}
    end

    def action?(name)
      if params[:action]
        params[:action] == name.to_s
      else
        unescape(request.path_info).ends_with? '/' + name.to_s
      end
    end

    def session
      env['rack.session'] ||= {}
    end

    def render(name, opts = {})
      layout = opts.delete(:layout)
      output = super(name, opts)
      if layout != false
        content = super(:layout, opts) { output }
        doc = Nokogiri::XML(content) # Nokogiri::XML(content, nil, 'UTF-8', Nokogiri::XML::ParseOptions::STRICT)
        invoke_hook :layout, name, doc
        output = doc.to_xhtml(:encoding => 'UTF-8')
      end
      output
    end
  end
end
