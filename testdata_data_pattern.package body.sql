create or replace package body testdata_data_pattern

as

  procedure find_known_pattern_in_col (
    metadata              in out nocopy       testdata_ninja.main_tab_meta
    , col_idx             in                  number
  )

  as

    type sample_data_tab is table of varchar2(4000);
    l_sample_data         sample_data_tab := sample_data_tab();
    l_sample_data_cursor  sys_refcursor;

    -- Sample and pattern variables.
    type pattern_count_tab is table of number index by varchar2(100);
    pattern_count         pattern_count_tab;
    l_sample_size         number;
    l_pattern_sql         varchar2(4000) := 'select regexp_count(:b1, :b2) from dual';
    l_pattern_out         number;
    l_pattern_idx         varchar2(100);
    l_pattern_hit         number := 0;
    l_guessed_pattern     varchar2(250) := null;
    l_guessed_arguments   varchar2(4000) := null;

  begin

    dbms_application_info.set_action('find_known_pattern_in_col');

    -- Find the sample size for the cursor. Never fetch more than testdata_data_infer.g_column_value_max_sample_size
    -- and by default we fetch 1% if table rowcount is larger than 200 and .
    -- Else we fetch the entire table.
    if round(metadata.table_base_stats.num_rows/100) > testdata_data_infer.g_column_value_max_sample_size then
      -- calculate the percent of 1000 rows.
      l_sample_size := ((1000/metadata.table_base_stats.num_rows*100)/100);
    elsif metadata.table_base_stats.num_rows > 200 then
      l_sample_size := 1;
    else
      -- Might as well fetch entire table.
      l_sample_size := 99;
    end if;

    -- Fetching the data sample as a single bulk collect. Should be optimized later and maybe cached in the main object
    -- for reuse later on if needed.
    open l_sample_data_cursor for 'select ' || metadata.table_columns(col_idx).column_name || ' from ' || metadata.table_name || ' sample(' || l_sample_size || ')';
    fetch l_sample_data_cursor bulk collect into l_sample_data;

    for i in 1..l_sample_data.count loop
      for y in 1..pattern_dict.count loop
        execute immediate l_pattern_sql into l_pattern_out using l_sample_data(i), pattern_dict(y).regexp_pattern;
        if l_pattern_out = 1 then
          if pattern_count.exists(y) then
            pattern_count(y) := pattern_count(y) + 1;
          else
            pattern_count(y) := 1;
          end if;
        end if;
        l_pattern_out := 0;
      end loop;
    end loop;

    if pattern_count.count = 1 then
      l_guessed_pattern := pattern_dict(pattern_count.first).random_generator;
      l_guessed_arguments := pattern_dict(pattern_count.first).generator_args;
    elsif pattern_count.count > 1 then
      -- Find the pattern with the most hits and choose that.
      l_pattern_idx := pattern_count.first;
      while l_pattern_idx is not null loop
        if to_number(pattern_count(l_pattern_idx)) > l_pattern_hit then
          l_guessed_pattern := pattern_dict(l_pattern_idx).random_generator;
          l_guessed_arguments := pattern_dict(l_pattern_idx).generator_args;
          l_pattern_hit := to_number(pattern_count(l_pattern_idx));
        end if;
        l_pattern_idx := pattern_count.next(l_pattern_idx);
      end loop;
    else
      -- This is where we should simply relook at the data once again
      -- and do our own pattern analysis.
      null;
    end if;

    metadata.table_columns(col_idx).inf_col_type := 'generated';
    metadata.table_columns(col_idx).inf_col_generator := l_guessed_pattern;
    metadata.table_columns(col_idx).inf_col_generator_args := l_guessed_arguments;

    dbms_application_info.set_action(null);

  end find_known_pattern_in_col;

  procedure guess_pattern_in_col (
    metadata              in out nocopy       testdata_ninja.main_tab_meta
    , col_idx             in                  number
  )

  as

    type row_pattern_rec is record (
      col_val                     varchar2(4000)
      , word_count                number
      , max_word_count            number
      , min_word_count            number
      , int_count                 number
      , has_caps                  number
      , caps_count                number
      , low_count                 number
      , seperator_count           number
      , seperator_avg_count       number
      , seperator_min_count       number
      , seperator_max_count       number
      , all_count                 number
      , avg_count_by_seperator    number
      , min_count_by_seperator    number
      , max_count_by_seperator    number
      , patternized               varchar2(4000)
      , seperator_value           varchar2(100)
    );
    type sample_data_tab is table of row_pattern_rec;
    l_sample_data         sample_data_tab := sample_data_tab();
    l_sample_data_cursor  sys_refcursor;
    l_sample_size         number;
    type pattern_histo_tab is table of number index by varchar2(4000);
    l_pattern_histogram   pattern_histo_tab;
    l_pattern             varchar2(4000);
    type pattern_section_rec is record (
        sec_min_length      number
        , sec_max_length    number
        , sec_has_numeric   number
        , sec_numeric_inc   number
        , sec_num_start     number
    );
    type pattern_section_tab is table of pattern_section_rec;
    l_pattern_sections    pattern_section_tab := pattern_section_tab();
    l_section_length      number;
    l_section_value       varchar2(4000);
    l_section_int_count   number;
    l_section_prev_int_p  number;

    l_only_one_word       boolean := false;
    l_id_word_pattern     boolean := false;
    l_caps_count          number;
    l_low_count           number;

    l_has_pattern         boolean := false;

  begin

    dbms_application_info.set_action('guess_pattern_in_col');

    -- Find the sample size for the cursor. Never fetch more than testdata_data_infer.g_column_value_max_sample_size
    -- and by default we fetch 1% if table rowcount is larger than 200 and .
    -- Else we fetch the entire table.
    if round(metadata.table_base_stats.num_rows/100) > testdata_data_infer.g_column_value_max_sample_size then
      -- calculate the percent of 1000 rows.
      l_sample_size := ((1000/metadata.table_base_stats.num_rows*100)/100);
    elsif metadata.table_base_stats.num_rows > 200 then
      l_sample_size := 1;
    else
      -- Might as well fetch entire table.
      l_sample_size := 99;
    end if;

    open l_sample_data_cursor for 'select
        '|| metadata.table_columns(col_idx).column_name ||'
        , wcount
        , max(wcount) over () as maxwcount
        , min(wcount) over () as minwcount
        , intcount
        , case
            when capcount > 0 then 1
            else 0
          end hascaps
        , capcount
        , lowcount
        , sepcount
        , round(avg(sepcount) over ()) as avesepcount
        , min(sepcount) over () as minsepcount
        , max(sepcount) over () as maxsepcount
        , allcount
        , round(avg(allcount) over(partition by sepcount)) as avgallcountbysep
        , min(allcount) over (partition by sepcount) as minallcountbysep
        , max(allcount) over (partition by sepcount) as maxallcountbysep
        , case
            when wcount-sepcount = 1 then regexp_replace(regexp_replace('|| metadata.table_columns(col_idx).column_name ||', ''\d'', ''#''), ''[a-zA-Z]'', ''?'')
            when (wcount-sepcount = 0 and sepcount = 1) then regexp_replace(regexp_replace('|| metadata.table_columns(col_idx).column_name ||', ''\d'', ''#''), ''[a-zA-Z]'', ''?'')
            else null
          end patternized
        , case
            when (wcount-sepcount = 1 and sepcount > 0) then regexp_substr('|| metadata.table_columns(col_idx).column_name ||', ''[-_/\|]'')
            when (wcount-sepcount = 0 and sepcount = 1) then regexp_substr('|| metadata.table_columns(col_idx).column_name ||', ''[-_/\|]'')
            else null
          end sepvalue
      from (
        select
          '|| metadata.table_columns(col_idx).column_name ||'
          , regexp_count('|| metadata.table_columns(col_idx).column_name ||', ''\w+'') as wcount
          , regexp_count('|| metadata.table_columns(col_idx).column_name ||', ''\d'') as intcount
          , regexp_count('|| metadata.table_columns(col_idx).column_name ||', ''[A-Z]'') as capcount
          , regexp_count('|| metadata.table_columns(col_idx).column_name ||', ''[a-z]'') as lowcount
          , regexp_count('|| metadata.table_columns(col_idx).column_name ||', ''[-_/\|]'') as sepcount
          , length('|| metadata.table_columns(col_idx).column_name ||') as allcount
        from ' || metadata.table_name || ' sample(' || l_sample_size || ')
      )';
    fetch l_sample_data_cursor bulk collect into l_sample_data;

    for i in 1..l_sample_data.count loop
      -- For the first row let us set some base assumptions.
      if i = 1 then
        if l_sample_data(i).max_word_count = 1 then
          l_only_one_word := true;
        end if;
        if l_sample_data(i).seperator_avg_count > 0 then
          l_id_word_pattern := true;
        end if;
      end if;
      -- Pattern related checks
      if l_sample_data(i).patternized is not null then
        l_has_pattern := true;
        if l_pattern_histogram.exists(l_sample_data(i).patternized) then
          l_pattern_histogram(l_sample_data(i).patternized) := l_pattern_histogram(l_sample_data(i).patternized) + 1;
        else
          l_pattern_histogram(l_sample_data(i).patternized) := 1;
        end if;
        -- Pattern section related
        for y in 1..(l_sample_data(i).seperator_count + 1) loop
          l_section_value := util_random.ru_extract(l_sample_data(i).patternized, y, l_sample_data(i).seperator_value);
          l_section_length := length(l_section_value);
          l_section_int_count := regexp_count(l_section_value, '\d');
          if l_pattern_sections.exists(y) then
            if l_section_length < l_pattern_sections(y).sec_min_length then
              l_pattern_sections(y).sec_min_length := l_section_length;
            end if;
            if l_section_length > l_pattern_sections(y).sec_max_length then
              l_pattern_sections(y).sec_max_length := l_section_length;
            end if;
          else
            l_pattern_sections.extend(1);
            l_pattern_sections(y).sec_min_length := l_section_length;
            l_pattern_sections(y).sec_max_length := l_section_length;
            l_pattern_sections(y).sec_has_numeric := 0;
            l_pattern_sections(y).sec_numeric_inc := 0;
            l_pattern_sections(y).sec_num_start := 0;
          end if;
          -- Generics
          if l_sample_data(i).int_count > 0 then
            l_pattern_sections(y).sec_has_numeric := 1;
            -- Check if all numeric for this section
            if l_section_length = l_section_int_count then
              if to_number(l_section_value) > l_pattern_sections(y).sec_numeric_inc and l_pattern_sections(y).sec_numeric_inc >= 0 then
                -- Number section is still incrementing.
                l_pattern_sections(y).sec_numeric_inc := to_number(l_section_value);
              else
                l_pattern_sections(y).sec_numeric_inc := -1;
              end if;
            else
              -- We have integers mixed with characters
              -- Find out if spread out between characters or they are placed sequentially somewhere in string.
              for x in 1..l_section_int_count loop
                if l_section_prev_int_p is null then
                  l_section_prev_int_p := regexp_instr(l_section_value, '\d', 1);
                else
                  if regexp_instr(l_section_value, '\d', l_section_prev_int_p + 1) > l_section_prev_int_p + 1 then
                    -- Number is not sequentially placed in string.
                    l_pattern_sections(y).sec_numeric_inc := -1;
                  end if;
                end if;
              end loop;
              -- Here we know if sec_numeric_inc is >= 0 the number is sequentially placed
              -- and we know that the number is starting at l_section_prev_int_p and is l_section_int_count long.
              -- Extract and see if the number is increasing.
              if to_number(substr(l_section_value, l_section_prev_int_p, l_section_int_count)) > l_pattern_sections(y).sec_numeric_inc and l_pattern_sections(y).sec_numeric_inc >= 0 then
                l_pattern_sections(y).sec_numeric_inc := to_number(substr(l_section_value, l_section_prev_int_p, l_section_int_count));
              end if;
              l_section_prev_int_p := null;
            end if;
          end if;
        end loop;
      end if;
    end loop;

    close l_sample_data_cursor;

    -- Whatever pattern built up, we can return.
    if l_has_pattern then
      -- If count of histograms is 1, we dont have to randomise the input to numcharfy.
      if l_pattern_histogram.count = 1 then
        l_pattern := l_pattern_histogram(l_pattern_histogram.first);
      else
        -- We have more than one pattern in the fabricated patterns.
        -- Lets check if we can find some common ground.
        -- First check if seperated sections are all the same size, if seperated.
        if l_sample_data(1).seperator_min_count > 0 and l_sample_data(1).seperator_min_count = l_sample_data(1).seperator_max_count then
          -- Seperated and all samples has same separator count.
          -- check length of each pattern section
          for i in 1..l_pattern_sections.count loop
            if l_pattern_sections(i).sec_min_length = l_pattern_sections(i).sec_max_length then
              -- This section is always same length
              if l_pattern_sections(i).sec_has_numeric > 0 and l_pattern_sections(i).sec_numeric_inc > 0 then
                -- TODO: FIX IF to real. Add increase check
                -- This section has number(s) and it is increasing, so make sure to do same.
                -- TODO: Actually replace number wildcards, with incrementor call.
                l_pattern := l_pattern || l_sample_data(1).seperator_value || util_random.ru_extract(l_sample_data(1).patternized, i, l_sample_data(1).seperator_value);
              else
                l_pattern := l_pattern || l_sample_data(1).seperator_value || util_random.ru_extract(l_sample_data(1).patternized, i, l_sample_data(1).seperator_value);
              end if;
            else
              -- This section is variable length
              if l_pattern_sections(i).sec_has_numeric > 0 and l_pattern_sections(i).sec_numeric_inc > 0 then
                -- TODO: FIX IF to check if actaully increasing.
                -- Increasing number
                -- TODO: Actually replace number wildcards, with incrementor call.
                l_pattern := l_pattern || l_sample_data(1).seperator_value || ''' || substr(rpad('' '', core_random.r_natural(' || l_pattern_sections(i).sec_min_length ||',' || l_pattern_sections(i).sec_max_length || ') + 1, ''?''), 2) || ''';
              else
                l_pattern := l_pattern || l_sample_data(1).seperator_value || ''' || substr(rpad('' '', core_random.r_natural(' || l_pattern_sections(i).sec_min_length ||',' || l_pattern_sections(i).sec_max_length || ') + 1, ''?''), 2) || ''';
              end if;
            end if;
            null;
          end loop;
          l_pattern := substr(l_pattern, 2);
        elsif l_sample_data(1).seperator_min_count > 0 and l_sample_data(1).seperator_min_count != l_sample_data(1).seperator_max_count then
          -- TODO: This is where we build patterns with different seperator counts.
          null;
        else
          -- This is where we build pattern for strings without seperator
          l_pattern := ''' || substr(rpad('' '', core_random.r_natural(' || l_sample_data(1).min_count_by_seperator ||',' || l_sample_data(1).max_count_by_seperator || ') + 1, ''?''), 2) || ''';
        end if;
      end if;
      metadata.table_columns(col_idx).inf_col_type := 'generated';
      metadata.table_columns(col_idx).inf_col_generator := 'util_random.ru_numcharfy';
      if l_sample_data(1).caps_count > 0 and l_sample_data(1).low_count = 0 then
        metadata.table_columns(col_idx).inf_col_generator_args := 'ru_string => ''' || l_pattern || ''', ru_upper => true';
      else
        metadata.table_columns(col_idx).inf_col_generator_args := 'ru_string => ''' || l_pattern || ''', ru_upper => false';
      end if;
    end if;

    dbms_application_info.set_action(null);

    /*exception
      when others then
        dbms_application_info.set_action(null);
        raise; */

  end guess_pattern_in_col;

begin

  dbms_application_info.set_client_info('testdata_data_pattern');
  dbms_session.set_identifier('testdata_data_pattern');

  pattern_dict := pattern_dict_tab();

  pattern_dict.extend(9);

  pattern_dict(1).regexp_pattern := '^\d{4}([ \-]?)((\d{6}\1?\d{5})|(\d{4}\1?\d{4}\1?\d{4}))$';
  pattern_dict(1).random_generator := 'util_random.ru_display_format';
  pattern_dict(1).generator_args := 'finance_random.r_creditcardnum, ''????-????-????-????'', false';
  pattern_dict(1).pattern_name := 'Creditcard number';
  pattern_dict(2).regexp_pattern := '^[a-zA-Z]{2,15}\s([a-zA-Z.]{1,15}\s)?[a-zA-Z.]{2,15}$';
  pattern_dict(2).random_generator := 'person_random.r_name';
  pattern_dict(2).generator_args := null;
  pattern_dict(2).pattern_name := 'Full name';
  pattern_dict(3).regexp_pattern := '^[0-9]{1,15}\s([a-zA-Z]{2,15}\s)?[a-zA-Z.]{2,15}$';
  pattern_dict(3).random_generator := 'location_random.r_address';
  pattern_dict(3).generator_args := null;
  pattern_dict(3).pattern_name := 'Address';
  pattern_dict(4).regexp_pattern := '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$';
  pattern_dict(4).random_generator := 'web_random.r_ipv4';
  pattern_dict(4).generator_args := null;
  pattern_dict(4).pattern_name := 'IP4 Address';
  pattern_dict(5).regexp_pattern := '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,3}';
  pattern_dict(5).random_generator := 'web_random.r_email';
  pattern_dict(5).generator_args := null;
  pattern_dict(5).pattern_name := 'Email';
  pattern_dict(6).regexp_pattern := '^[A-Z]{2}[0-9]{10}$';
  pattern_dict(6).random_generator := 'investment_random.r_isincode';
  pattern_dict(6).generator_args := null;
  pattern_dict(6).pattern_name := 'ISIN code';
  pattern_dict(7).regexp_pattern := '^[a-f0-9]{32}$';
  pattern_dict(7).random_generator := 'computer_random.r_md5';
  pattern_dict(7).generator_args := null;
  pattern_dict(7).pattern_name := 'MD5';
  pattern_dict(8).regexp_pattern := '^(http:\/\/www\.|https:\/\/www\.|http:\/\/|https:\/\/)?[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(:[0-9]{1,5})?(\/.*)?$';
  pattern_dict(8).random_generator := 'web_random.r_url';
  pattern_dict(8).generator_args := null;
  pattern_dict(8).pattern_name := 'URL';

end testdata_data_pattern;
/
