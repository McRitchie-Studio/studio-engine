# frozen_string_literal: true

require "bigdecimal"
require "date"

module Studio
  module KnowledgePreview
    # Renders a spreadsheet cell's stored number the way its number format
    # says to, which is what separates a readable financial statement from a
    # grid of raw floats: 45382 is a date, 0.0825 is 8.25%, -1234.5 is
    # (1,234.50).
    #
    # It reads the format CODE (the string Excel shows under Format Cells >
    # Custom), so a custom format works as well as a built-in one. Covered:
    # positive;negative;zero sections, thousands grouping, fixed and optional
    # decimals, percent, currency and other literal prefixes and suffixes,
    # accounting padding, trailing-comma scaling, scientific notation, and
    # date and time tokens in both date systems. Not covered, and rendered as
    # a plain number instead: fractions ("# ?/?") and conditional sections
    # ("[>100]"). Colours are dropped.
    module NumberFormat
      BUILTIN = {
        0 => "General", 1 => "0", 2 => "0.00", 3 => "#,##0", 4 => "#,##0.00",
        9 => "0%", 10 => "0.00%", 11 => "0.00E+00", 12 => "# ?/?", 13 => "# ??/??",
        14 => "m/d/yyyy", 15 => "d-mmm-yy", 16 => "d-mmm", 17 => "mmm-yy",
        18 => "h:mm AM/PM", 19 => "h:mm:ss AM/PM", 20 => "h:mm", 21 => "h:mm:ss",
        22 => "m/d/yyyy h:mm",
        37 => "#,##0 ;(#,##0)", 38 => "#,##0 ;[Red](#,##0)",
        39 => "#,##0.00;(#,##0.00)", 40 => "#,##0.00;[Red](#,##0.00)",
        41 => '_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)',
        42 => '_("$"* #,##0_);_("$"* \(#,##0\);_("$"* "-"_);_(@_)',
        43 => '_(* #,##0.00_);_(* \(#,##0.00\);_(* "-"??_);_(@_)',
        44 => '_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)',
        45 => "mm:ss", 46 => "[h]:mm:ss", 47 => "mm:ss.0", 48 => "##0.0E+0", 49 => "@"
      }.freeze

      MONTHS = %w[January February March April May June July August September October November December].freeze
      DAYS   = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

      # Excel keeps 15 significant digits; rounding from that decimal reading
      # (not from the binary float) is what makes 1.005 show as 1.01.
      SIGNIFICANT_DIGITS = 15
      # Past the last second of 9999-12-31 a serial is not a date in either
      # system; such a cell renders as a plain number.
      MAX_DATE_SERIAL = 2_958_465

      module_function

      # The format code for a style's numFmtId: the workbook's own custom
      # formats first, then the built-in table, then General.
      def code_for(id, custom = {})
        custom[id] || BUILTIN[id] || "General"
      end

      def format(value, code, date1904: false)
        render(value, tokenize(code.to_s), date1904: date1904)
      end

      # The same, from sections already tokenized: a sheet's cells share a
      # handful of formats, so the reader tokenizes each one once.
      def render(value, sections, date1904: false)
        section, magnitude, signed = pick_section(sections, value)
        text =
          if section.any? { |kind, _| kind == :date || kind == :elapsed }
            format_date(value, section, date1904) || general(value)
          else
            format_number(magnitude, section, signed)
          end
        text.strip
      rescue ArgumentError, FloatDomainError, RangeError
        general(value)
      end

      def date_format?(code)
        tokenize(code.to_s).first.to_a.any? { |kind, _| kind == :date || kind == :elapsed }
      end

      # A number with no format: an integer without a decimal point, anything
      # else to ten significant digits with trailing zeros dropped.
      def general(value)
        return value.to_i.to_s if value.finite? && value == value.to_i && value.abs < 1e15

        Kernel.format("%.10g", value)
      end

      # --- sections -----------------------------------------------------------

      # => [section, value to render, whether to prepend a minus sign]
      def pick_section(sections, value)
        negative = value.negative?
        if sections.size >= 3 && value.zero?
          [sections[2], value, false]
        elsif sections.size >= 2 && negative
          [sections[1], value.abs, false]
        else
          [sections[0], value.abs, negative]
        end
      end

      def tokenize(code)
        sections = [[]]
        index = 0
        while index < code.length
          char = code[index]
          rest = code[index..]
          current = sections.last

          if char == ";"
            sections << []
            index += 1
          elsif char == '"'
            close = code.index('"', index + 1) || code.length
            current << [:literal, code[(index + 1)...close]]
            index = close + 1
          elsif char == "\\"
            current << [:literal, code[index + 1].to_s]
            index += 2
          elsif char == "_"
            current << [:literal, " "]
            index += 2
          elsif char == "*"
            index += 2
          elsif char == "["
            close = code.index("]", index) || code.length
            bracket(code[(index + 1)...close], current)
            index = close + 1
          elsif (word = rest[/\Ageneral/i])
            current << [:general, word]
            index += word.length
          elsif (marker = rest[/\A(?:AM\/PM|A\/P)/i])
            current << [:ampm, marker]
            index += marker.length
          elsif rest.match?(/\AE[+-]/i)
            current << [:exponent, rest[1]]
            index += 2
          elsif (run = rest[/\A(?:y+|m+|d+|h+|s+)/i])
            current << [:date, run.downcase]
            index += run.length
          elsif "0#?".include?(char)
            current << [:digit, char]
            index += 1
          elsif char == "."
            current << [:point, char]
            index += 1
          elsif char == ","
            current << [:comma, char]
            index += 1
          elsif char == "%"
            current << [:percent, char]
            index += 1
          elsif char == "@"
            current << [:text, char]
            index += 1
          elsif char == "/"
            current << [:slash, char]
            index += 1
          else
            current << [:literal, char]
            index += 1
          end
        end
        sections
      end

      # [$€-407] is a currency symbol with a locale; [h] is elapsed time; the
      # rest (colours, conditions) carries nothing a plain table can show.
      def bracket(body, section)
        if body.start_with?("$")
          symbol = body[1..].to_s.split("-", 2).first.to_s
          section << [:literal, symbol] unless symbol.empty?
        elsif body.match?(/\A(?:h+|m+|s+)\z/i)
          section << [:elapsed, body.downcase]
        end
      end

      # --- numbers ------------------------------------------------------------

      def format_number(value, section, signed)
        kinds = section.map(&:first)
        sign = signed ? "-" : ""
        return sign + literals(section) + general(value) if kinds.include?(:general)

        first = kinds.index { |kind| %i[digit point].include?(kind) }
        # A section with no digit placeholders is fixed text: accounting
        # formats render zero as "-" this way.
        return literals(section) if first.nil? && !kinds.include?(:text)
        return sign + general(value) if first.nil? || kinds.include?(:slash)

        last = kinds.rindex { |kind| %i[digit point].include?(kind) }
        prefix = literals(section[0...first])
        suffix = literals(section[(last + 1)..])
        body = section[first..last]
        # The exponent's own digits ("E+00") are not decimal places.
        exponent = body.index { |kind, _| kind == :exponent }
        body = body[0...exponent] if exponent

        value *= 100 if kinds.include?(:percent)
        point = body.index { |kind, _| kind == :point }
        integer_tokens = point ? body[0...point] : body
        decimal_tokens = point ? body[(point + 1)..] : []

        # Commas after the last digit placeholder scale by a thousand each;
        # a comma between placeholders asks for grouping.
        trailing = section[(last + 1)..].take_while { |kind, _| kind == :comma }.size
        trailing += integer_tokens.reverse.take_while { |kind, _| kind == :comma }.size
        value /= (1000.0**trailing) if trailing.positive?
        grouped = integer_tokens.each_cons(3).any? { |a, b, c| a[0] == :digit && b[0] == :comma && c[0] == :digit }

        decimal_digits = decimal_tokens.count { |kind, _| kind == :digit }
        if kinds.include?(:exponent)
          return sign + prefix + Kernel.format("%.#{decimal_digits}E", value) + suffix
        end

        minimum_decimals = decimal_tokens.count { |kind, mark| kind == :digit && mark == "0" }
        minimum_integers = integer_tokens.count { |kind, mark| kind == :digit && mark == "0" }

        rounded = BigDecimal(value, SIGNIFICANT_DIGITS).round(decimal_digits, BigDecimal::ROUND_HALF_UP)
        whole, fraction = rounded.to_s("F").split(".")
        fraction = fraction.to_s.ljust(decimal_digits, "0")[0, decimal_digits]
        fraction = fraction.sub(/0+\z/, "").ljust(minimum_decimals, "0")
        whole = "" if whole == "0" && minimum_integers.zero?
        whole = whole.rjust(minimum_integers, "0")
        whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse if grouped
        # A value that rounds to zero carries no minus sign: -0.001 at two
        # decimals is 0.00, not -0.00.
        sign = "" if rounded.zero?

        number = fraction.empty? ? whole : "#{whole}.#{fraction}"
        sign + prefix + number + suffix
      end

      def literals(tokens)
        tokens.to_a.filter_map { |kind, mark| mark if %i[literal percent].include?(kind) }.join
      end

      # --- dates --------------------------------------------------------------

      def format_date(serial, section, date1904)
        return nil if serial.negative? || serial > MAX_DATE_SERIAL

        days = serial.floor
        seconds = ((serial - days) * 86_400).round
        if seconds >= 86_400
          days += 1
          seconds = 0
        end
        date = date_for(days, date1904)
        hour, remainder = seconds.divmod(3600)
        minute, second = remainder.divmod(60)
        twelve_hour = section.any? { |kind, _| kind == :ampm }
        date_tokens = section.each_index.select { |i| %i[date elapsed].include?(section[i][0]) }

        section.each_with_index.map { |(kind, mark), index|
          case kind
          when :date
            date_part(mark, index, date_tokens, section, date, hour, minute, second, twelve_hour)
          when :elapsed
            elapsed_part(mark, serial)
          when :ampm
            meridiem = hour < 12 ? "AM" : "PM"
            mark.length == 3 ? meridiem[0] : meridiem
          when :digit then "0"
          when :general, :text, :exponent then ""
          else mark
          end
        }.join
      end

      # Serial 60 is 1900-02-29, a day Lotus 1-2-3 invented and Excel kept;
      # every later serial is one day ahead of the real calendar for it.
      def date_for(days, date1904)
        return Date.new(1904, 1, 1) + days if date1904

        days < 60 ? Date.new(1899, 12, 31) + days : Date.new(1899, 12, 30) + days
      end

      def date_part(mark, index, date_tokens, section, date, hour, minute, second, twelve_hour)
        case mark[0]
        when "y" then mark.length <= 2 ? Kernel.format("%02d", date.year % 100) : date.year.to_s
        when "d"
          case mark.length
          when 1 then date.day.to_s
          when 2 then Kernel.format("%02d", date.day)
          when 3 then DAYS[date.wday][0, 3]
          else DAYS[date.wday]
          end
        when "h"
          shown = twelve_hour ? ((hour % 12).zero? ? 12 : hour % 12) : hour
          mark.length == 1 ? shown.to_s : Kernel.format("%02d", shown)
        when "s" then mark.length == 1 ? second.to_s : Kernel.format("%02d", second)
        when "m"
          if minutes?(index, date_tokens, section)
            mark.length == 1 ? minute.to_s : Kernel.format("%02d", minute)
          else
            case mark.length
            when 1 then date.month.to_s
            when 2 then Kernel.format("%02d", date.month)
            when 3 then MONTHS[date.month - 1][0, 3]
            when 4 then MONTHS[date.month - 1]
            else MONTHS[date.month - 1][0]
            end
          end
        end
      end

      # "m" is minutes when the date token before it is hours or the one after
      # it is seconds, and months everywhere else.
      def minutes?(index, date_tokens, section)
        position = date_tokens.index(index)
        before = position.positive? ? section[date_tokens[position - 1]][1] : nil
        after = date_tokens[position + 1] ? section[date_tokens[position + 1]][1] : nil
        before.to_s.start_with?("h") || after.to_s.start_with?("s")
      end

      def elapsed_part(mark, serial)
        total =
          case mark[0]
          when "h" then (serial * 24).floor
          when "m" then (serial * 1440).floor
          else (serial * 86_400).round
          end
        total.to_s.rjust(mark.length, "0")
      end
    end
  end
end
