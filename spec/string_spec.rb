# frozen_string_literal: true

require 'spec_helper'

# https://github.com/thoiberg/cli-test
describe ::String do
  describe '#normalize_trigger' do
    context 'when a trigger contains parentheticals' do
      it 'normalizes the trigger' do
        expect('(https?)(?:://)'.normalize_trigger).to match(%r{\(\?:https\?\)\(\?:://\)})
      end
    end
  end

  describe '#parse_flags' do
    context 'when a search string contains short flags' do
      it 'parses short flags to long flags' do
        expect('test --d ++tv'.parse_flags).to match(/test --no-debug --include_titles --validate_links/)
      end
    end
  end

  describe '#fix_gist_file' do
    context 'when given a hyphenated filename' do
      it 'creates a gist-friendly filename' do
        expect('file-btt_touch-rb').to match(/btt_touch.rb/)
      end
    end
  end

  describe '#slugify' do
    context 'when given a phrase containing spaces and punctuation' do
      it 'slugifies the phrase' do
        expect('Hello there!'.slugify).to match(/hello-there/)
      end
    end
  end
end
