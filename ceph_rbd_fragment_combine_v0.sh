#!/bin/bash
# Author: Yu-Jung Cheng

rbd_prefix='3ceec238e1f29'
osd_path='/var/lib/ceph/osd/ceph-'
cp_to_path="/var/lib/ceph/osd/ceph-11/findrbd_02"
combine_dir="/var/lib/ceph/osd/ceph-6/_combine_${rbd_prefix}"

zero_4M_bytes_count=4194304
zero_4M_file="/tmp/4m_zero"

log_path='/var/log/dump_rbd_fragment.log'


osd_list=(0)

# =============================================================================

function dump_rbd_fragments() {
    echo "Start dump fragments: " `date` >> ${log_path}

    rm -rf ${cp_to_path}
    mkdir -p ${cp_to_path}

    for osd_id in ${osd_list[@]}; do
        echo "  OSD ID: ${osd_id}" >> ${log_path}
        cd_path="${osd_path}${osd_id}/current"

        find ${cd_path} -name "*${rbd_prefix}*" -print0 | xargs -I {} -0 cp -afpR {} ${cp_to_path}

        fragment_count=`ls -l ${cp_to_path}| grep -v total | wc -l`
        echo "  Number of segments: ${fragment_count}" >> ${log_path}
    done

    echo "Finish dump fragments: " `date` >> ${log_path}
}


function generate_padding_zero() {
    local padding_len=$1
    local combine_dir=$2
    dd if=/dev/zero of=${combine_dir}/${padding_len} bs=1 count=${padding_len} &> /dev/null
}

function add_padding_zero() {
    local fragment_name=$1
    local padding_zero=$2
    cat ${fragment_name} ${padding_zero} > ${fragment_name}_padded
    mv ${fragment_name}_padded ${fragment_name}
    rm -rf ${padding_zero}
}

function combined_rbd_fragements() {
    local lose_fragment_count=0
    local padding_fragment_count=0
    local raw_fragment_count=0
    
    echo "[ Start combine fragments: " `date` " ]" >> ${log_path}
    
    rm -rf ${combine_dir}
    mkdir -p ${combine_dir}

    # create 4M zero dummy file
    echo "  - DD 4M zero file."
    dd if=/dev/zero of=${zero_4M_file} bs=4096 count=1024 &> /dev/null

    echo "  - Get fragment file name list. ${cp_to_path}"
    #`ls -l ${cp_to_path} | grep -v "header.\|total" | awk -F ' ' '{print $9}' | sort`
    fragment_file_list=($(ls -l ${cp_to_path} | grep -v "header.\|total" | awk -F ' ' '{print $9}' | sort))

    previous_seq=0
    file_counter=0
    echo "  - Analysis fragment files."
    for name in ${fragment_file_list[@]}; do
        op=""

        # -----------------------------------------
        # get sequence number of fragment
        # -----------------------------------------
        file_hex_seq=`echo "${name}" | awk -F '.' '{print $3}' | awk -F '__' '{print $1}'`
        file_decimal_seq="$((16#${file_hex_seq}))"
        file_size=`ls -l "${cp_to_path}/${name}" | awk -F ' ' '{print $5}'`
        if [[ "${file_decimal_seq}" == "" ]]; then
            echo "unable to get fragment sequence number. ${name}"
            continue            
        fi
        #echo "    ${name} ${file_decimal_seq} ${file_size}"

        # -----------------------------------------
        # add zero file for lost fragment
        # -----------------------------------------
        if [[ "${file_counter}" -ne "${file_decimal_seq}" ]]; then
            seq_diff=$((${file_decimal_seq} - ${file_counter}))
            for i in `seq 1 ${seq_diff}`; do
                echo "    missing fragment. seq=${file_counter} op=cp zero"
                cp -afpR "${zero_4M_file}" "${combine_dir}/${file_counter}"
                file_counter=$((file_counter + 1))
                lose_fragment_count=$((lose_fragment_count + 1))
            done
        fi

        # -----------------------------------------
        # padding zero data to fragment
        # -----------------------------------------
        if [[ "${file_counter}" -eq "${file_decimal_seq}" ]]; then

            # get padding zero length
            padding_len=$((${zero_4M_bytes_count} - file_size))
            
            if [[ "${padding_len}" -eq "0" ]]; then
                op="cp fragment"
                cp -afpR "${cp_to_path}/${name}" "${combine_dir}/${file_decimal_seq}"

                raw_fragment_count=$((raw_fragment_count + 1))                
            elif [[ "${padding_len}" -eq "4194304" ]]; then
                op="cp zero"
                cp -afpR "${zero_4M_file}" "${combine_dir}/${file_decimal_seq}"
                
                lose_fragment_count=$((lose_fragment_count + 1))
            elif [[ "${padding_len}" -gt "0" ]]; then
                op="padding zero"
                cp -afpR "${cp_to_path}/${name}" "${combine_dir}/${file_decimal_seq}"

                generate_padding_zero ${padding_len} ${combine_dir}
                add_padding_zero "${combine_dir}/${file_decimal_seq}" "${combine_dir}/${padding_len}"
                
                padding_fragment_count=$((padding_fragment_count + 1))
            else
                op="skip"

            fi
            
        fi

        echo "    name=${name} seq=${file_decimal_seq} size=${file_size} op=${op}"

        file_counter=$((file_counter +1))
        #previous_seq=${file_decimal_seq}
        
    done
    
    echo "  - Completed Analysis fragment files"
    total_fragment=`ls -l ${combine_dir} | grep -v "total" | wc -l`
    
    echo "    Total Fragment Count      : ${total_fragment}"
    echo "    Raw Fragment Count        : ${raw_fragment_count}"
    echo "    Padded Fragment Count     : ${padding_fragment_count}"
    echo "    Zero Padded Fragment Count: ${lose_fragment_count}"
    
    echo "  - Start Combine fragment files."
    
    combined_file=${rbd_prefix}
    touch ${combine_dir}/${rbd_prefix}
    for i in `seq 0 $((total_fragment - 1))`; do

        echo "    combine ${i}"
        cat ${combine_dir}/${i} >> ${combine_dir}/${rbd_prefix}
        
    done
    
    echo "  - Done"
    ls_out=`ls -l ${combine_dir}/${rbd_prefix}`
    file_out=`file ${combine_dir}/${rbd_prefix}`
    echo "    ls -l: ${ls_out}" 
    echo "    file : ${file_out}" 

    echo "[ Finish combine fragments: " `date` " ]" >> ${log_path}
}

# =============================================================================
#dump_rbd_fragments
combined_rbd_fragements
