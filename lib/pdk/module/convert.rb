require 'pdk/generate/module'
require 'pdk/module/update_manager'
require 'pdk/util'
require 'pdk/report'

module PDK
  module Module
    class Convert
      def self.invoke(options)
        update_manager = PDK::Module::UpdateManager.new
        template_url = options.fetch(:'template-url', PDK::Util.default_template_url)

        PDK::Module::TemplateDir.new(template_url, nil, false) do |templates|
          new_metadata = update_metadata('metadata.json', templates.metadata, options)

          if options[:noop] && new_metadata.nil?
            update_manager.add_file('metadata.json', '')
          elsif File.file?('metadata.json')
            update_manager.modify_file('metadata.json', new_metadata)
          else
            update_manager.add_file('metadata.json', new_metadata)
          end

          templates.render do |file_path, file_content|
            if File.exist? file_path
              update_manager.modify_file(file_path, file_content)
            else
              update_manager.add_file(file_path, file_content)
            end
          end
        end

        unless update_manager.changes?
          PDK::Report.default_target.puts(_('No changes required.'))
          return
        end

        # Print the summary to the default target of reports
        summary = get_summary(update_manager)
        print_summary(summary)

        # Generates the full convert report
        full_report(update_manager) unless update_manager.changes[:modified].empty?

        return if options[:noop]

        unless options[:force]
          PDK.logger.info _(
            'Module conversion is a potentially destructive action. ' \
            'Ensure that you have committed your module to a version control ' \
            'system or have a backup, and review the changes above before continuing.',
          )
          continue = PDK::CLI::Util.prompt_for_yes(_('Do you want to continue and make these changes to your module?'))
          return unless continue
        end

        # Mark these files for removal after generating the report as these
        # changes are not something that the user needs to review.
        if update_manager.changed?('Gemfile')
          update_manager.remove_file('Gemfile.lock')
          update_manager.remove_file(File.join('.bundle', 'config'))
        end

        update_manager.sync_changes!

        PDK::Util::Bundler.ensure_bundle! if update_manager.changed?('Gemfile')

        print_result(summary)
      end

      def self.update_metadata(metadata_path, template_metadata, options = {})
        if File.file?(metadata_path)
          if File.readable?(metadata_path)
            begin
              metadata = PDK::Module::Metadata.from_file(metadata_path)
              new_values = PDK::Module::Metadata::DEFAULTS.reject { |key, _| metadata.data.key?(key) }
              metadata.update!(new_values)
            rescue ArgumentError
              metadata = PDK::Generate::Module.prepare_metadata(options) unless options[:noop] # rubocop:disable Metrics/BlockNesting
            end
          else
            raise PDK::CLI::ExitWithError, _('Unable to convert module metadata; %{path} exists but it is not readable.') % {
              path: metadata_path,
            }
          end
        elsif File.exist?(metadata_path)
          raise PDK::CLI::ExitWithError, _('Unable to convert module metadata; %{path} exists but it is not a file.') % {
            path: metadata_path,
          }
        else
          return nil if options[:noop]

          project_dir = File.basename(Dir.pwd)
          options[:module_name] = project_dir.split('-', 2).compact[-1]
          options[:prompt] = false
          options[:'skip-interview'] = true if options[:force]

          metadata = PDK::Generate::Module.prepare_metadata(options)
        end

        metadata.update!(template_metadata)
        metadata.to_json
      end

      def self.get_summary(update_manager)
        summary = {}
        update_manager.changes.each do |category, update_category|
          updated_files = if update_category.respond_to?(:keys)
                            update_category.keys
                          else
                            update_category.map { |file| file[:path] }
                          end

          summary[category] = updated_files
        end

        summary
      end

      def self.print_summary(summary)
        footer = false

        summary.keys.each do |category|
          next if summary[category].empty?

          PDK::Report.default_target.puts(_("\n%{banner}") % { banner: generate_banner("Files to be #{category}", 40) })
          PDK::Report.default_target.puts(summary[category])
          footer = true
        end

        PDK::Report.default_target.puts(_("\n%{banner}") % { banner: generate_banner('', 40) }) if footer
      end

      def self.print_result(summary)
        PDK::Report.default_target.puts(_("\n%{banner}") % { banner: generate_banner('Convert completed', 40) })
        summary_to_print = summary.map { |k, v| "#{v.length} files #{k}" unless v.empty? }.compact
        PDK::Report.default_target.puts(_("\n%{summary}\n\n") % { summary: "#{summary_to_print.join(', ')}." })
      end

      def self.full_report(update_manager)
        File.open('convert_report.txt', 'w') do |f|
          f.write("/* Convert Report generated by PDK at #{Time.now} */")
          update_manager.changes[:modified].each do |_, diff|
            f.write("\n\n\n" + diff)
          end
        end
        PDK::Report.default_target.puts(_("\nYou can find a report of differences in convert_report.txt.\n\n"))
      end

      def self.generate_banner(text, width = 80)
        padding = width - text.length
        banner = ''
        padding_char = '-'

        (padding / 2.0).ceil.times { banner << padding_char }
        banner << text
        (padding / 2.0).floor.times { banner << padding_char }

        banner
      end
    end
  end
end
