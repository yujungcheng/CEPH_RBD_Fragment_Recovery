#!/bin/bash
# Author: Yu-Jung Cheng
#
# This script is used to find rbd objects in ceph osd node and combine them 
# together to recovery completed RBD image. For missing objects, use 4M zero file.
# For object less than 4M, padding zero to make object size to 4M.
#

# =============================================================================
# Global Variables
# =============================================================================

# you should modify
rbd_prefix='3ceec238e1f29'
cp_to_path="/tmp/_dump_${rbd_prefix}"
combine_dir="/tmp/_combine_${rbd_prefix}"
osd_list=(0 1 2)
rbd_pool_id=0


# you "SHOULD NOT" modify
zero_4M_bytes_count=4194304
osd_path='/var/lib/ceph/osd/ceph-'
zero_4M_file="/tmp/4m_zero"
op_log_path="/var/log/ceph_rbd_fragment_recovery"
op_log_file="${op_log_path}/${rbd_prefix}_op.log"
mkdir -p "${op_log_path}"

echo 
echo "Before started, you may empty the log file if necessary. Start in 5 seconds"
echo "- rbd prefix : ${rbd_prefix}"  | tee -a ${op_log_file}
echo "- path cp to : ${cp_to_path}"  | tee -a ${op_log_file}
echo "- combine dir: ${combine_dir}" | tee -a ${op_log_file}
echo "- osd id list: ${osd_list[@]}" | tee -a ${op_log_file}
echo "- rbd pool id: ${rbd_pool_id}" | tee -a ${op_log_file}
sleep 5

echo

# =============================================================================
# Functions
# =============================================================================
function dump_rbd_fragments() {

    echo -e "\n[ Start dump fragments: " `date` " ]" | tee -a ${op_log_file}

    rm -rf ${cp_to_path}
    mkdir -p ${cp_to_path}

    for osd_id in ${osd_list[@]}; do
        echo "  OSD ID: ${osd_id}" | tee -a ${op_log_file}
        
        if [[ "${rbd_pool_id}" -ne "" ]]; then
            cd_path="${osd_path}${osd_id}/current/${rbd_pool_id}.*_head"
        else
            cd_path="${osd_path}${osd_id}/current/*_head"
        fi

        # -iname : case insensitive, -name : case sensitive
        find ${cd_path} -iname "*${rbd_prefix}*" -print0 | xargs -I {} -0 cp -afpR {} ${cp_to_path}

        fragment_count=`ls -l ${cp_to_path}| grep -v total | wc -l`
        echo "  Number of segments: ${fragment_count}" | tee -a ${op_log_file}
    done

    echo "Finish dump fragments: " `date` " ]" | tee -a ${op_log_file}
    return 0
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
    local size_invalid_count=0
    
    echo -e "\n[ Start combine fragments: " `date` " ]" | tee -a ${op_log_file}
    
    rm -rf ${combine_dir}
    mkdir -p ${combine_dir}

    # create 4M zero dummy file
    echo "  - DD 4M zero file." | tee -a ${op_log_file}
    dd if=/dev/zero of=${zero_4M_file} bs=4096 count=1024 &> /dev/null

    echo "  - Get fragment file name list." | tee -a ${op_log_file}
    #`ls -l ${cp_to_path} | grep -v "header.\|total" | awk -F ' ' '{print $9}' | sort`
    fragment_file_list=($(ls -l ${cp_to_path} | grep -v "header.\|total" | awk -F ' ' '{print $9}' | sort))

    file_counter=0
    echo "  - Analysis fragment files." | tee -a ${op_log_file}
    for name in ${fragment_file_list[@]}; do
        op=""

        # -----------------------------------------
        # get sequence number of fragment
        # -----------------------------------------
        file_hex_seq=`echo "${name}" | awk -F '.' '{print $3}' | awk -F '__' '{print $1}'`
        file_decimal_seq="$((16#${file_hex_seq}))"
        file_size=`ls -l "${cp_to_path}/${name}" | awk -F ' ' '{print $5}'`
        if [[ "${file_decimal_seq}" == "" ]]; then
            echo "unable to get fragment sequence number. ${name}" | tee -a ${op_log_file}
            continue            
        fi
        #echo "    ${name} ${file_decimal_seq} ${file_size}"

        # -----------------------------------------
        # add zero file for lost fragment
        # -----------------------------------------
        if [[ "${file_counter}" -ne "${file_decimal_seq}" ]]; then
            seq_diff=$((${file_decimal_seq} - ${file_counter}))
            for i in `seq 1 ${seq_diff}`; do
                echo "    missing fragment. seq=${file_counter} op=cp zero" | tee -a ${op_log_file}
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
            # *this is value indicate length of missing data
            padding_len=$((${zero_4M_bytes_count} - file_size))
            
            if [[ "${padding_len}" -eq "0" ]]; then
                # - object size is 4M, no padding zero required
                op="cp fragment"
                cp -afpR "${cp_to_path}/${name}" "${combine_dir}/${file_decimal_seq}"
                
                # - double check cp success or not
                if [[ -e "${combine_dir}/${file_decimal_seq}" ]]; then
                    raw_fragment_count=$((raw_fragment_count + 1))
                else
                    op="cp fragment failed, do cp zero"
                    cp -afpR "${zero_4M_file}" "${combine_dir}/${file_decimal_seq}"
                    lose_fragment_count=$((lose_fragment_count + 1))
                fi
                
            elif [[ "${padding_len}" -eq "${zero_4M_bytes_count}" ]]; then
                # - object size is 0, padding 4M zero
                op="cp zero"
                cp -afpR "${zero_4M_file}" "${combine_dir}/${file_decimal_seq}"
                
                lose_fragment_count=$((lose_fragment_count + 1))

            elif [[ "${padding_len}" -gt "0" ]]; then
                # - object size greater than 0, less than 4194304
                op="padding zero"
                cp -afpR "${cp_to_path}/${name}" "${combine_dir}/${file_decimal_seq}"

                generate_padding_zero ${padding_len} ${combine_dir}
                add_padding_zero "${combine_dir}/${file_decimal_seq}" "${combine_dir}/${padding_len}"
                
                padding_fragment_count=$((padding_fragment_count + 1))
            else
                # - size is not valid (should less or equal 4194304)
                op="invalid size, cp zero"
                cp -afpR "${zero_4M_file}" "${combine_dir}/${file_decimal_seq}"
                size_invalid_count=$((size_invalid_count + 1))
            fi
            
        fi

        echo "    name=${name} seq=${file_decimal_seq} size=${file_size} op=${op}" | tee -a ${op_log_file}

        file_counter=$((file_counter +1))
        
    done
    
    echo "  - Completed Analysis fragment files" | tee -a ${op_log_file}

    # count line of ls output in combine dir
    total_fragment=`ls -l ${combine_dir} | grep -v "total" | wc -l`
    
    # show statistics
    echo "    Total Fragment Count      : ${total_fragment}"         | tee -a ${op_log_file}
    echo "    Internal File Counter     : ${file_counter}"           | tee -a ${op_log_file}
    echo "    Raw Fragment Count        : ${raw_fragment_count}"     | tee -a ${op_log_file}
    echo "    Padded Fragment Count     : ${padding_fragment_count}" | tee -a ${op_log_file}
    echo "    Zero Padded Fragment Count: ${lose_fragment_count}"    | tee -a ${op_log_file}
    
    # combine fragments
    echo "  - Start Combine fragment files." | tee -a ${op_log_file}    
    combined_file=${rbd_prefix}
    touch ${combine_dir}/${rbd_prefix}
    for i in `seq 0 $((total_fragment - 1))`; do
        
        cat ${combine_dir}/${i} >> ${combine_dir}/${rbd_prefix}
        if [[ "$?" -ne "0" ]]; then
            echo "    combine ${i} error, $?" | tee -a ${op_log_file}
        else
            echo "    combine ${i} success, $?" | tee -a ${op_log_file}
        fi
        
    done
    echo "  - Done" | tee -a ${op_log_file}

    # check file system and size
    ls_out=`ls -l ${combine_dir}/${rbd_prefix}`
    file_out=`file ${combine_dir}/${rbd_prefix}`
    echo "    ls -l: ${ls_out}"  | tee -a ${op_log_file}
    echo "    file : ${file_out}"  | tee -a ${op_log_file}
    

    echo "[ Finish combine fragments: " `date` " ]" | tee -a ${op_log_file}
}


# =============================================================================
# Main
# =============================================================================

dump_rbd_fragments

if [[ "$?" -eq "0" ]]; then
    combined_rbd_fragements
fi
