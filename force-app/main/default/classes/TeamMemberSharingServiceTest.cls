/**
 * @description Tests share access ranking, partial DML errors, and team-member lookup without the
 * active filter.
 * @author Melissa Rainboldt
 */
@IsTest
private class TeamMemberSharingServiceTest {

    /**
     * @description Verifies max access prefers all over edit over read.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testMaxAccessPrefersAllOverEditOverRead() {
        System.assertEquals('Edit', TeamMemberSharingService.maxAccess('Read', 'Edit'));
        System.assertEquals('All', TeamMemberSharingService.maxAccess('Edit', 'All'));
        System.assertEquals('All', TeamMemberSharingService.maxAccess('Read', 'All'));
        System.assertEquals('Read', TeamMemberSharingService.maxAccess('Read', null));
        System.assertEquals('Edit', TeamMemberSharingService.maxAccess(null, 'Edit'));
        System.assertEquals(
            'All',
            TeamMemberSharingService.maxAccess(
                TeamMemberSharingService.maxAccess('Read', 'Edit'),
                'All'));
    }

    /**
     * @description Verifies access rank is case insensitive.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testAccessRankIsCaseInsensitive() {
        System.assertEquals(
            TeamMemberSharingService.accessRank('Edit'),
            TeamMemberSharingService.accessRank('edit'));
        System.assert(
            TeamMemberSharingService.accessRank('All')
                > TeamMemberSharingService.accessRank('Edit'));
        System.assert(
            TeamMemberSharingService.accessRank('Edit')
                > TeamMemberSharingService.accessRank('Read'));
        System.assertEquals(0, TeamMemberSharingService.accessRank(null));
        System.assertEquals(0, TeamMemberSharingService.accessRank('None'));
    }

    /**
     * @description Verifies throw if share DML failed noops when empty.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testThrowIfShareDmlFailedNoopsWhenEmpty() {
        TeamMemberSharingService.throwIfShareDmlFailed('insert', null);
        TeamMemberSharingService.throwIfShareDmlFailed('delete', new List<String>());
    }

    /**
     * @description Verifies throw if share DML failed surfaces errors.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testThrowIfShareDmlFailedSurfacesErrors() {
        Boolean threw = false;
        try {
            TeamMemberSharingService.throwIfShareDmlFailed(
                'insert',
                new List<String>{
                    'FIELD_INTEGRITY_EXCEPTION: bad',
                    'INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY: x'
                });
        } catch (SharingConfigService.SharingException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Share insert failed for 2 row(s)'),
                e.getMessage());
            System.assert(e.getMessage().contains('FIELD_INTEGRITY_EXCEPTION'), e.getMessage());
        }
        System.assert(threw, 'Share DML errors must throw so queue workers markFailed');
    }

    /**
     * @description Verifies insert shares throws on DML error.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testInsertSharesThrowsOnDmlError() {
        Team_Member_Config__c parent = new Team_Member_Config__c(
            Name = 'Share DML fail',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Is_Active__c = true,
            Application__c = 'OCC'
        );
        insert parent;

        Type shareType = Type.forName('Team_Member_Config__Share');
        System.assertNotEquals(null, shareType, 'Private OWD should expose a share object');
        SObject share = (SObject) shareType.newInstance();
        share.put('ParentId', parent.Id);
        share.put('UserOrGroupId', UserInfo.getUserId());
        share.put('AccessLevel', 'NotALevel');
        share.put('RowCause', 'Manual');

        Boolean threw = false;
        try {
            TeamMemberSharingService.insertShares(new List<SObject>{ share });
        } catch (SharingConfigService.SharingException e) {
            threw = true;
            System.assert(e.getMessage().contains('Share insert failed'), e.getMessage());
        }
        System.assert(threw, 'Non-duplicate share insert errors must throw');
    }

    /**
     * @description Verifies insert shares partial does not throw.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testInsertSharesPartialDoesNotThrow() {
        Team_Member_Config__c parent = new Team_Member_Config__c(
            Name = 'Partial share DML',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Is_Active__c = true,
            Application__c = 'OCC'
        );
        insert parent;

        Type shareType = Type.forName('Team_Member_Config__Share');
        System.assertNotEquals(null, shareType);
        SObject share = (SObject) shareType.newInstance();
        share.put('ParentId', parent.Id);
        share.put('UserOrGroupId', UserInfo.getUserId());
        share.put('AccessLevel', 'NotALevel');
        share.put('RowCause', 'Manual');

        TeamMemberSharingService.ShareDmlOutcome outcome =
            TeamMemberSharingService.insertSharesPartial(new List<SObject>{ share });
        System.assertEquals(true, outcome.hasFatal());
        System.assertEquals(1, outcome.attempted);
        System.assert(
            !outcome.fatalByShareKey.isEmpty() || !outcome.fatalMessages.isEmpty(),
            String.join(outcome.fatalMessages, '; '));
    }

    /**
     * @description Verifies query team member by Id ignores active filter.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testQueryTeamMemberByIdIgnoresActiveFilter() {
        insert new Team_Member_Config__c(
            Name = 'GLS TM by id',
            Team_Member_Object_Api_Name__c = 'Contact',
            Parent_Lookup_Field_Api_Name__c = 'AccountId',
            User_Field_Api_Name__c = 'OwnerId',
            Access_Level_Field_Api_Name__c = 'Description',
            Active_Field_Api_Name__c = 'HasOptedOutOfEmail',
            Use_Team_Member_Access_Level__c = true,
            Is_Active__c = true,
            Application__c = 'GLS'
        );
        SharingConfigService.resetCache();
        SharingConfigService cfg = SharingConfigService.getInstance('GLS');

        Account account = new Account(Name = 'Parent');
        insert account;
        Contact tm = new Contact(
            LastName = 'Inactive flag',
            AccountId = account.Id,
            Description = 'Edit',
            HasOptedOutOfEmail = false
        );
        insert tm;

        System.assertEquals(
            0,
            TeamMemberSharingService.queryTeamMembers(new Set<Id>{ account.Id }, cfg).size(),
            'Active filter should exclude the new Contact');
        SObject loaded = TeamMemberSharingService.queryTeamMemberById(tm.Id, cfg);
        System.assertNotEquals(null, loaded);
        System.assertEquals(tm.Id, loaded.Id);
        System.assertEquals(UserInfo.getUserId(), TeamMemberSharingService.userOrGroupId(
            loaded, cfg.teamMemberConfig));
        System.assertEquals(null, TeamMemberSharingService.queryTeamMemberById(account.Id, cfg));
        System.assertEquals(null, TeamMemberSharingService.queryTeamMemberById(null, cfg));

        Map<Id, SObject> byIds = TeamMemberSharingService.queryTeamMembersByIds(
            new Set<Id>{ tm.Id, account.Id }, cfg);
        System.assertEquals(1, byIds.size(), 'Unknown Id must not appear in the map');
        System.assertEquals(tm.Id, byIds.get(tm.Id).Id);
        System.assertEquals(true, TeamMemberSharingService.queryTeamMembersByIds(
            new Set<Id>(), cfg).isEmpty());
        System.assertEquals(true, TeamMemberSharingService.queryTeamMembersByIds(null, cfg).isEmpty());
    }

    /**
     * @description Verifies insert share row skips when OWD already grants.
     * @author Melissa Rainboldt
     * @return void
     */
    @IsTest
    static void testInsertShareRowSkipsWhenOwdAlreadyGrants() {
        SharingConfigService.resetCache();
        SharingConfigService.owdModelOverride.put('team_member_config__c', 'ReadWrite');
        Team_Member_Config__c parent = new Team_Member_Config__c(
            Name = 'OWD skip',
            Team_Member_Object_Api_Name__c = 'User',
            Parent_Lookup_Field_Api_Name__c = 'Id',
            User_Field_Api_Name__c = 'Id',
            Is_Active__c = true,
            Application__c = 'OCC'
        );
        insert parent;

        Integer processed = TeamMemberSharingService.insertShareRow(
            'Team_Member_Config__c',
            parent.Id,
            UserInfo.getUserId(),
            'Edit',
            'Manual');
        System.assertEquals(0, processed);
        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Team_Member_Config__Share
                WHERE ParentId = :parent.Id
                AND UserOrGroupId = :UserInfo.getUserId()
                AND RowCause = 'Manual'
            ]);
    }
}
