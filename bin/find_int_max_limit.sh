#!/bin/bash

# ---------------------------------------------------------------------------------------------
# NAME          : find_int_max_limit.sh
# DESC          : To scan to find integer columns to identify if it is approaching the max limits
# OWNER         : SK
# CREATED AT    : 06/25/2025
# UPDATED AT    : 07/08/2025
# VERSION       : 1.3
# ---------------------------------------------------------------------------------------------

# DATE              # CHANGE HISTORY                                    # UPDATED BY
# 2025/06/30        Added log and email options                         SK
# 2025/07/02        Added command check                                 SK
# 2025/07/08        Excluding BIGINT to reduce execution time           SK
#                   Added Madhur and Pawan into the email list

MYCNF=/home/skhurelbat/.my.cnf   # DB credentials to connect database
THRESHOLD_ALERT_PCT=80           # Flag ones that are using more than X% (eg. 90%)  of their allowed value range.
dots=""                          # Initialize an empty string  to store dots
beyond_threshold_columns=0       # count the columns which are approaching their max limit
beyond_threshold_columns_list=() # list the column details which are approaching their max limit
log_path="/tmp/identify_integer" # log file generating path
TIMESTAMP=$(echo $(date "+%Y%m%d_%T") | tr -d ":")
email_on=1                       # flag for email report
email_recipient="skhurelbat@convoso.com, psubedi@convoso.com, mpant@convoso.com"

# QUERY - COUNT ALL INTEGER
query_count="SELECT COUNT(*) FROM information_schema.tables t
JOIN information_schema.columns c USING (table_schema, TABLE_NAME)
WHERE t.table_schema IN ('asterisk') and c.DATA_TYPE IN ('int', 'mediumint', 'smallint', 'tinyint');"

# QUERY - ALL INTEGER QUERY DETAILED
query_list="SELECT table_schema, table_name, column_name, CAST(POW(2, case data_type
 when 'tinyint' then 7
 when 'smallint' then 15
 when 'mediumint' then 23
 when 'int' then 31
 when 'bigint' then 63 END+(column_type LIKE '% unsigned')) AS DECIMAL(65,0))-1 AS max_int, data_type
FROM information_schema.tables t
JOIN information_schema.columns c USING (table_schema, TABLE_NAME)
WHERE t.table_schema IN ('asterisk') and c.DATA_TYPE IN ('int', 'mediumint', 'smallint', 'tinyint')
-- LIMIT 10
;"

log() {
    echo -e "$(date "+%Y%m%d %T") $@" | tee -a $log_file
}

log_notime() {
    echo -e "$@" | tee -a $log_file
}

create_log() {
    if [[ ! -d $log_path ]]; then
        mkdir -p $log_path
    fi
    log_file="${log_path}/${INSTANCE_NAME}_${TIMESTAMP}.log"
    touch $log_file
}

check_commands() {
    command -v "$1" >/dev/null 2>&1
}

send_email() {
    if [[ $email_on -eq 1 ]]; then
        from="identify_integer@$(hostname)"
        to=$email_recipient
        cur_date=$(date +"%F")
        subject="[$(hostname)] - integer threshold report - $INSTANCE_NAME - $cur_date"
        extra_message="$@"
        temp_body="/tmp/identify_integer_tmp.log"
        echo $extra_message >>$temp_body
        cat $log_file | grep "$cur_date" >>$temp_body
        cat $log_file | mail -s "$subject" -r $from $to
    fi
}

check_db_status() {
    db_running=$(mysql --defaults-file=$MYCNF -S $SOCK -e "SELECT 1;" -ANs 2>/dev/null)
    if [[ $db_running -eq 1 ]]; then
        log "INFO - Successfully connected DB via $SOCK"
    else
        log "ERROR - Unable to connect DB instance for $SOCK"
        exit 1
    fi
}

find_integers() {
    # CHECKING TOTAL INTEGER COLUMNS COUNTS
    log "INFO - Counting the all integer columns"
    total_int_columns=$(echo $query_count | mysql --defaults-file=$MYCNF -A -N -r -S $SOCK)
    log "INFO - Total: $total_int_columns integer columns. Checking..."

    # USED FOR ITERATION AND PRINT DOT TO MAKE SURE IT IS RUNNING
    counter=0

    # LOOPING ALL INTEGER COLUMNS FOR FURTHER CHECK DETAILS
    while IFS= read -r row; do
        table_schema=$(echo $row | awk '{print $1}')
        table_name=$(echo $row | awk '{print $2}')
        column_name=$(echo $row | awk '{print $3}')
        max_int=$(echo $row | awk '{print $4}')
        data_type=$(echo $row | awk '{print $5}')

        # APPEND DOTS TO THE STRING EVERY 200 ITERATIONS
        if [[ $((counter % 200)) -eq 0 ]]; then
            dots+="."
            printf "%s\r" "$dots"
        fi

        # PREPARING QUERY TO CHECK EACH COLUMN MAX VALUE
        q="SELECT IFNULL(max($column_name),0) as col_max FROM $table_schema.$table_name;"

        # CHECKING EACH COLUMN MAX VALUE
        column_max_value=$(mysql --defaults-file=$MYCNF -A -N -r -S $SOCK -e "$q")

        # CALCULATING THE PERCENTAGE OF EACH COLUMN CURRENT VALUE WITH MAXIMUM LIMIT
        percentage=$(echo "scale=0;$column_max_value * 100 / $max_int / 1" | bc)

        # DEBUGGING PURPOSE
        #echo "Query: $q"
        #echo -e "Checking: $table_name.$column_name => \t$percentage%"

        # IF THE COLUMN USAGE PERCENTAGE IS HIGHER THAN THRESHOLD VALUE, THEN IT IS COUNTING AND ADDING INTO ARRAY LIST
        if [[ $percentage -gt $THRESHOLD_ALERT_PCT ]]; then
            ((beyond_threshold_columns++))
            beyond_threshold_columns_list+=($table_schema"\t"$table_name"\t"$column_name"\t"$max_int"\t"$column_max_value"\t"$percentage"%\t"$data_type)
        fi

        # INCREMENT COUNTER FOR EACH ITERATION
        ((counter++))

    done < <(mysql --defaults-file=$MYCNF -A -N -r -S $SOCK -e "$query_list")

    log_notime ''

    # FINAL CHECK IF THERE ARE COLUMNS ARE IN THRESHOLD LIST
    if [[ $beyond_threshold_columns -eq 0 ]]; then
        log_notime "---------------------------------------------------------------------------------"
        log "GOOD: ALL INTEGER DATA TYPE COLUMNS ARE FINE FOR $total_int_columns"
    else
        log_notime "---------------------------------------------------------------------------------"
        log_notime "WARNING: There are $beyond_threshold_columns columns for total $total_int_columns that are approaching their max limit. Please find details below."
        log_notime "---------------------------------------------------------------------------------"
        log_notime "SCHEMA NAME\tTABLE NAME\tCOLUMN NAME\tCOLUMN DATA TYPE MAX\tCOLUMN MAX VALUE\tPERCENTAGE\tDATA TYPE"
        for row in "${beyond_threshold_columns_list[@]}"; do
            log_notime $row
        done
        log_notime "---------------------------------------------------------------------------------"
        log "INFO - The script has been completed!"
    fi
}

email_send() {
    log "INFO - Sending email"
    send_email "There are $beyond_threshold_columns columns for total $total_int_columns that are approaching their max limit. Please find details below.
SCHEMA NAME\tTABLE NAME\tCOLUMN NAME\tCOLUMN DATA TYPE MAX\tCOLUMN MAX VALUE\tPERCENTAGE\tDATA TYPE"
}

main() {

    if [[ $1 == "" ]]; then
        echo -e "Usage: $0 DB_SOCK
        Example: $0 /sql/d02-c05/run/mysqld.sock"
        exit 1
    else
        if [[ $1 == *"mysqld.sock"* ]]; then
            SOCK=$1
            INSTANCE_NAME=$(echo $SOCK | cut -d'/' -f3)
            create_log
            log_notime "---------------------------------------------------------------------------------"
            log "INFO - The script is starting!"
            log "INFO - Connecting to DB using socket=> $SOCK ..."
            check_db_status
            log_notime "---------------------------------------------------------------------------------"
        else
            echo -e 'Please enter the correct socket. See the available socks below.'
            find /sql/ . -name mysqld.sock 2>/dev/null | sort
            echo -e "Usage: $0 DB_SOCK
        Example: $0 /sql/d02-c05/run/mysqld.sock"
            exit 1
        fi
    fi

    check_commands bc
    if [[ $? != 0 ]]; then
        log "ERROR: Please install bc!!!."
        exit 1
    fi

    find_integers

    email_send

}

main "$@"
