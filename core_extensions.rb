require 'i18n'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end

  # from https://gist.github.com/Integralist/9503099
  def symbolize_keys
    return self.reduce({}) do |memo, (k, v)|
      memo.tap { |m| m[k.to_sym] = v.symbolize_keys }
    end if self.is_a? Hash

    return self.reduce([]) do |memo, v|
      memo << v.symbolize_keys; memo
    end if self.is_a? Array

    self
  end
end

class String
  def capitalize_first
    self[0] = self[0].capitalize
    self
  end
  alias_method :ucfirst, :capitalize_first

  def uncapitalize
    self[0, 1].downcase + self[1..-1]
  end

  def uppercase?
    match(/\p{Upper}/).present?
  end

  def lowercase?
    !uppercase?
  end

  def capitalized?
    self[0, 1].uppercase?
  end

  def score
    tr(' ', '_')
  end

  def descore
    tr('_', ' ')
  end

  def translate(opts = {})
    I18n.t(self, opts)
  end
  alias_method :t, :translate

  def pluralize(count = 0)
    "#{self}#{count == 1 ? '' : 's'}"
  end

  def pluralize_num(count = 0)
    "#{count} #{self.pluralize(count)}"
  end
end

def t(key, opts = {})
  if I18n.locale == :en && opts.blank?
    key
  elsif key.is_a?(Symbol)
    I18n.t(key, opts)
  else
    res = key.clone.uncapitalize.translate(opts)
    key.capitalized? ? res.capitalize_first : res.uncapitalize
  end
end
